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

/// True when the journal body has at least one non-empty, non-heading line.
/// Heading-only cartouches (`## Notes` with no prose) do not count.
pub fn has_journal_body(notes: &str) -> bool {
    let re = heading_re();
    notes.lines().any(|line| {
        let t = line.trim();
        !t.is_empty() && !re.is_match(line)
    })
}

fn is_h2_heading(line: &str) -> bool {
    heading_re()
        .captures(line)
        .is_some_and(|caps| caps[1].len() == 2)
}

/// 0-based indices of `##` headings, skipping fenced code.
fn h2_heading_indices(lines: &[&str]) -> Vec<usize> {
    let mut starts = Vec::new();
    let mut in_fence = false;
    for (i, line) in lines.iter().enumerate() {
        if is_fence_tick(line) {
            in_fence = !in_fence;
            continue;
        }
        if !in_fence && is_h2_heading(line) {
            starts.push(i);
        }
    }
    starts
}

fn section_end_after_h2(lines: &[&str], heading_idx: usize) -> usize {
    let re = heading_re();
    let mut j = heading_idx + 1;
    let mut in_fence = false;
    while j < lines.len() {
        if is_fence_tick(lines[j]) {
            in_fence = !in_fence;
        } else if !in_fence
            && let Some(next) = re.captures(lines[j])
            && next[1].len() <= 2
        {
            break;
        }
        j += 1;
    }
    j
}

/// Inclusive start / exclusive end of the first `n` `##` sections
/// (heading lines included). `None` when the note has no `##`.
fn first_h2_span(lines: &[&str], n: usize) -> Option<(usize, usize)> {
    if n == 0 {
        return None;
    }
    let starts = h2_heading_indices(lines);
    if starts.is_empty() {
        return None;
    }
    let start = starts[0];
    let last = starts[n.min(starts.len()) - 1];
    Some((start, section_end_after_h2(lines, last)))
}

/// Every `##` section as `(heading, body)` pairs. The heading line is not
/// included in the body; `###` subsections stay inside their parent.
pub fn extract_h2_sections(content: &str) -> Vec<(String, String)> {
    let lines: Vec<&str> = content.lines().collect();
    let starts = h2_heading_indices(&lines);
    let re = heading_re();
    let mut out = Vec::with_capacity(starts.len());
    for &idx in &starts {
        let title = re
            .captures(lines[idx])
            .map(|caps| caps[2].trim().to_string())
            .unwrap_or_default();
        let end = section_end_after_h2(&lines, idx);
        let body = if idx + 1 < end {
            trim_section_body(&lines[idx + 1..end].join("\n"))
        } else {
            String::new()
        };
        out.push((title, body));
    }
    out
}

/// Titles of `##` headings, in file order, capped at `limit`.
pub fn h2_titles(content: &str, limit: usize) -> Vec<String> {
    extract_h2_sections(content)
        .into_iter()
        .map(|(heading, _)| heading)
        .take(limit)
        .collect()
}

/// First `n` `##` sections, including the heading lines themselves.
/// Empty when the note has no `##`.
pub fn extract_first_h2_sections(content: &str, n: usize) -> String {
    if n == 0 {
        return String::new();
    }
    let lines: Vec<&str> = content.lines().collect();
    let Some((start, end)) = first_h2_span(&lines, n) else {
        return String::new();
    };
    trim_section_body(&lines[start..end].join("\n"))
}

/// Replace the span covering the first `n` `##` sections. The rest of the
/// note (Tasks, reviews, …) is left untouched. When the note has no `##`,
/// the new body is prepended.
pub fn replace_first_h2_sections(content: &str, n: usize, new_body: &str) -> String {
    let body = new_body.trim_end();
    let lines: Vec<&str> = content.lines().collect();
    let mut out: Vec<String> = Vec::new();
    if let Some((start, end)) = first_h2_span(&lines, n) {
        for line in lines.iter().take(start) {
            out.push((*line).to_string());
        }
        if !body.is_empty() {
            for line in body.lines() {
                out.push(line.to_string());
            }
        }
        for line in lines.iter().skip(end) {
            out.push((*line).to_string());
        }
    } else {
        if !body.is_empty() {
            for line in body.lines() {
                out.push(line.to_string());
            }
        }
        if !lines.is_empty() && out.last().is_none_or(|s| !s.is_empty()) {
            out.push(String::new());
        }
        for line in &lines {
            out.push((*line).to_string());
        }
    }
    let mut next = out.join("\n");
    if !next.ends_with('\n') {
        next.push('\n');
    }
    next
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
    let mut lines: Vec<&str> = body.lines().collect();
    while lines.first().is_some_and(|line| line.trim().is_empty()) {
        lines.remove(0);
    }
    while lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }
    lines.join("\n")
}

/// Replace the body under `heading`, or append a new `## heading` section.
/// Empty heading rewrites the journal while keeping checkbox todos.
pub fn replace_or_append_section(content: &str, heading: &str, new_body: &str) -> String {
    let heading = heading.trim();
    let body = trim_section_body(new_body);
    if heading.is_empty() {
        return merge_journal_preserving_checkboxes(content, &body);
    }
    let lines: Vec<&str> = content.lines().collect();
    let mut out: Vec<String> = Vec::new();

    if let Some((heading_idx, _start, end)) = find_section_range(&lines, heading) {
        for line in lines.iter().take(heading_idx + 1) {
            out.push((*line).to_string());
        }
        for line in body.lines() {
            out.push(line.to_string());
        }
        for line in lines.iter().skip(end) {
            out.push((*line).to_string());
        }
    } else {
        out.extend(lines.iter().map(|s| (*s).to_string()));
        while out.last().is_some_and(|s| s.is_empty()) {
            out.pop();
        }
        out.push(format!("## {heading}"));
        for line in body.lines() {
            out.push(line.to_string());
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
        let content =
            "# Day\n\n## Todos\n\n- [ ] a\n\n## Notes\n\nHello\n\nWorld\n\n## Later\n\nx\n";
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
        assert_eq!(next, "# Day\n\n## Notes\nnew\nline\n## Other\n\nz\n");
    }

    #[test]
    fn appends_notes_when_missing() {
        let content = "# Day\n\n## Todos\n\n- [ ] a\n";
        let next = replace_or_append_section(content, "Notes", "journal");
        assert_eq!(
            next,
            "# Day\n\n## Todos\n\n- [ ] a\n## Notes\njournal\n"
        );
    }

    #[test]
    fn ignores_heading_inside_fence() {
        let content = "## Notes\n\n```\n## Fake\n```\n\nreal\n\n## Next\n";
        assert_eq!(
            extract_section(content, "Notes"),
            "```\n## Fake\n```\n\nreal"
        );
    }

    fn daily_template_note() -> &'static str {
        "## Notes\n\
         ## Links / captured ideas\n\
         - a captured link\n\
         ## Tasks\n\
         - [x] a real task\n\
         ## Morning review\n\
         - [ ] Lire une méditation stoïque\n\
         ## Nightly review\n\
         - [ ] Regarder l’agenda de demain\n"
    }

    #[test]
    fn h2_titles_caps_at_seven() {
        assert_eq!(
            h2_titles(daily_template_note(), 7),
            vec![
                "Notes",
                "Links / captured ideas",
                "Tasks",
                "Morning review",
                "Nightly review"
            ]
        );
        assert_eq!(h2_titles(daily_template_note(), 2), vec!["Notes", "Links / captured ideas"]);
        let extra = "## A\n## B\n## C\n## D\n## E\n## F\n## G\n## H\n";
        assert_eq!(h2_titles(extra, 7).len(), 7);
        assert_eq!(h2_titles(extra, 7)[6], "G");
    }

    #[test]
    fn extracts_each_h2_body_including_review_checkboxes() {
        let sections = extract_h2_sections(daily_template_note());
        assert_eq!(
            sections.iter().map(|(t, _)| t.as_str()).collect::<Vec<_>>(),
            [
                "Notes",
                "Links / captured ideas",
                "Tasks",
                "Morning review",
                "Nightly review"
            ]
        );
        assert_eq!(sections[0].1, "");
        assert_eq!(sections[1].1, "- a captured link");
        assert_eq!(sections[2].1, "- [x] a real task");
        assert_eq!(sections[3].1, "- [ ] Lire une méditation stoïque");
        assert_eq!(sections[4].1, "- [ ] Regarder l’agenda de demain");
    }

    #[test]
    fn extracts_first_two_h2_sections_including_headings() {
        let body = extract_first_h2_sections(daily_template_note(), 2);
        assert_eq!(
            body,
            "## Notes\n## Links / captured ideas\n- a captured link"
        );
        assert!(has_journal_body(&body));
        assert!(!body.contains("Tasks"));
        assert!(!body.contains("méditation"));
        assert!(!has_journal_body("## Notes\n## Links / captured ideas"));
    }

    #[test]
    fn replace_first_two_h2_leaves_tasks_and_reviews() {
        let next = replace_first_h2_sections(
            daily_template_note(),
            2,
            "## Notes\n- a thought\n## Links / captured ideas\n- a captured link",
        );
        assert!(
            next.starts_with(
                "## Notes\n- a thought\n## Links / captured ideas\n- a captured link\n"
            )
        );
        assert!(next.contains("## Tasks\n- [x] a real task\n"));
        assert!(next.contains("## Morning review\n- [ ] Lire une méditation stoïque\n"));
        assert!(next.contains("## Nightly review\n"));
    }

    #[test]
    fn replace_section_has_no_padding_blank_lines() {
        let content = "## Notes\n\ntest\n\n## Links / captured ideas\n";
        let next = replace_or_append_section(content, "Notes", "test\n");
        assert_eq!(next, "## Notes\ntest\n## Links / captured ideas\n");
    }
}
