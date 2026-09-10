//! Extract and replace a markdown section used as the free-form notes body.

use regex::Regex;

fn heading_re() -> Regex {
    Regex::new(r"^(#{1,6})\s+(.+?)\s*$").expect("heading regex")
}

/// Inclusive start / exclusive end as 0-based line indices for the section
/// body (content under the heading, not including the heading line itself).
fn find_section_range(lines: &[&str], heading: &str) -> Option<(usize, usize, usize)> {
    let want = heading.trim().to_lowercase();
    if want.is_empty() {
        return None;
    }
    let re = heading_re();
    let mut i = 0usize;
    while i < lines.len() {
        if let Some(caps) = re.captures(lines[i]) {
            let level = caps[1].len();
            let title = caps[2].trim().to_lowercase();
            if title == want {
                let body_start = i + 1;
                let mut j = body_start;
                let mut in_fence = false;
                while j < lines.len() {
                    let trimmed = lines[j].trim_start();
                    if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
                        in_fence = !in_fence;
                    } else if !in_fence
                        && let Some(next) = re.captures(lines[j])
                        && next[1].len() <= level
                    {
                        break;
                    }
                    j += 1;
                }
                // heading_idx, body_start, body_end (exclusive)
                return Some((i, body_start, j));
            }
        }
        i += 1;
    }
    None
}

fn checkbox_re() -> Regex {
    Regex::new(r"^(\s*)([-*+])\s+\[([ xX])\](\s+)(.*)$").expect("checkbox regex")
}

fn tasks_heading_re() -> Regex {
    Regex::new(r"(?i)^#{1,6}\s+(tasks|todos)\s*$").expect("tasks heading regex")
}

fn is_fence_tick(line: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with("```") || trimmed.starts_with("~~~")
}

/// Whole-file journal: checkbox todos belong in the todo list, not the note.
fn extract_whole_note_journal(content: &str) -> String {
    let checkbox = checkbox_re();
    let tasks_heading = tasks_heading_re();
    let mut kept: Vec<&str> = Vec::new();
    let mut in_fence = false;
    for line in content.lines() {
        if is_fence_tick(line) {
            in_fence = !in_fence;
            kept.push(line);
            continue;
        }
        if !in_fence && (checkbox.is_match(line) || tasks_heading.is_match(line)) {
            continue;
        }
        kept.push(line);
    }
    let mut body = kept.join("\n");
    while body.contains("\n\n\n") {
        body = body.replace("\n\n\n", "\n\n");
    }
    trim_section_body(&body)
}

/// True when the journal body has at least one non-empty line. Checkbox-only
/// notes yield an empty body after extract, so they do not count.
pub fn has_journal_body(notes: &str) -> bool {
    notes.lines().any(|line| !line.trim().is_empty())
}

fn merge_journal_preserving_checkboxes(content: &str, new_body: &str) -> String {
    let checkbox = checkbox_re();
    let mut todos: Vec<String> = Vec::new();
    let mut in_fence = false;
    for line in content.lines() {
        if is_fence_tick(line) {
            in_fence = !in_fence;
            continue;
        }
        if !in_fence && checkbox.is_match(line) {
            todos.push(line.to_string());
        }
    }
    let body = extract_whole_note_journal(new_body);
    let mut next = String::new();
    if !todos.is_empty() {
        next.push_str(&todos.join("\n"));
        next.push('\n');
        if !body.is_empty() {
            next.push('\n');
        }
    }
    if !body.is_empty() {
        next.push_str(&body);
        next.push('\n');
    } else if !next.is_empty() && !next.ends_with('\n') {
        next.push('\n');
    }
    next
}

/// Body under a markdown heading (trimmed). Empty heading = the whole note
/// minus checkbox todos (those are the todo list). Empty string when a named
/// heading is missing.
pub fn extract_section(content: &str, heading: &str) -> String {
    if heading.trim().is_empty() {
        return extract_whole_note_journal(content);
    }
    let lines: Vec<&str> = content.lines().collect();
    let Some((_, start, end)) = find_section_range(&lines, heading) else {
        return String::new();
    };
    let body = lines[start..end].join("\n");
    trim_section_body(&body)
}

fn trim_section_body(body: &str) -> String {
    // Drop a single leading blank line (common after headings) and trailing
    // whitespace, but keep intentional internal blank lines.
    let mut s = body.to_string();
    if s.starts_with('\n') {
        s = s[1..].to_string();
    }
    s.trim_end().to_string()
}

/// Replace the body under `heading`, or append a new `## heading` section.
/// Empty heading rewrites the journal while keeping checkbox todos.
pub fn replace_or_append_section(content: &str, heading: &str, new_body: &str) -> String {
    let heading = heading.trim();
    let body = new_body.trim_end();
    if heading.is_empty() {
        return merge_journal_preserving_checkboxes(content, body);
    }
    let lines: Vec<&str> = content.lines().collect();
    let mut out: Vec<String> = Vec::new();

    if let Some((heading_idx, _start, end)) = find_section_range(&lines, heading) {
        for line in lines.iter().take(heading_idx + 1) {
            out.push((*line).to_string());
        }
        // Keep one blank line after the heading when the body is non-empty.
        if !body.is_empty() {
            out.push(String::new());
            for line in body.lines() {
                out.push(line.to_string());
            }
        }
        // Keep a blank-line boundary before the next peer heading when present.
        if end < lines.len() && out.last().is_none_or(|s| !s.is_empty()) {
            out.push(String::new());
        }
        for line in lines.iter().skip(end) {
            out.push((*line).to_string());
        }
    } else {
        out.extend(lines.iter().map(|s| (*s).to_string()));
        while out.last().is_some_and(|s| s.is_empty()) {
            out.pop();
        }
        if !out.is_empty() {
            out.push(String::new());
        }
        out.push(format!("## {heading}"));
        out.push(String::new());
        if !body.is_empty() {
            for line in body.lines() {
                out.push(line.to_string());
            }
        }
    }

    let mut next = out.join("\n");
    if !next.ends_with('\n') {
        next.push('\n');
    }
    next
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_notes_section() {
        let content = "# Day\n\n## Todos\n\n- [ ] a\n\n## Notes\n\nHello\n\nWorld\n\n## Later\n\nx\n";
        assert_eq!(extract_section(content, "Notes"), "Hello\n\nWorld");
        assert_eq!(extract_section(content, "missing"), "");
        assert_eq!(
            extract_section(content, ""),
            "# Day\n\n## Notes\n\nHello\n\nWorld\n\n## Later\n\nx"
        );
    }

    #[test]
    fn empty_heading_omits_checkbox_todos() {
        let content = "- [ ] buy milk\n- [x] done\n\n- walked the dog\n";
        assert_eq!(extract_section(content, ""), "- walked the dog");
        assert!(has_journal_body(&extract_section(content, "")));
        assert!(!has_journal_body(&extract_section(
            "- [ ] only a todo\n- [x] done\n\n",
            ""
        )));
        assert!(!has_journal_body("   \n\n"));
    }

    #[test]
    fn empty_heading_replaces_whole_note() {
        assert_eq!(
            replace_or_append_section("# old\n", "", "- new journal\n"),
            "- new journal\n"
        );
    }

    #[test]
    fn empty_heading_replace_keeps_checkboxes() {
        let next = replace_or_append_section(
            "- [x] done\n\nold journal\n",
            "",
            "new journal\n- [ ] leftover in textarea",
        );
        assert_eq!(next, "- [x] done\n\nnew journal\n");
    }

    #[test]
    fn replaces_existing_notes() {
        let content = "# Day\n\n## Notes\n\nold\n\n## Other\n\nz\n";
        let next = replace_or_append_section(content, "Notes", "new\nline");
        assert_eq!(next, "# Day\n\n## Notes\n\nnew\nline\n\n## Other\n\nz\n");
    }

    #[test]
    fn appends_notes_when_missing() {
        let content = "# Day\n\n## Todos\n\n- [ ] a\n";
        let next = replace_or_append_section(content, "Notes", "journal");
        assert_eq!(
            next,
            "# Day\n\n## Todos\n\n- [ ] a\n\n## Notes\n\njournal\n"
        );
    }

    #[test]
    fn ignores_heading_inside_fence() {
        let content = "## Notes\n\n```\n## Fake\n```\n\nreal\n\n## Next\n";
        assert_eq!(extract_section(content, "Notes"), "```\n## Fake\n```\n\nreal");
    }
}
