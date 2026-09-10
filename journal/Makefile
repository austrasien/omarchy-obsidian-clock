CARGO ?= cargo

.PHONY: build test fmt clippy clean install-bin

build:
	$(CARGO) build --release

# Copy the host-arch binary into the plugin's bin/ next to this crate.
install-bin: build
	install -Dm755 target/release/obsidian-daily-qs ../bin/obsidian-daily-qs-$$(uname -m)
	install -Dm755 target/release/obsidian-daily-qs ../bin/obsidian-daily-qs

test:
	$(CARGO) test --all-targets

fmt:
	$(CARGO) fmt

clippy:
	$(CARGO) clippy --all-targets -- -D warnings

clean:
	$(CARGO) clean
