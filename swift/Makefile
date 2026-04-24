BINARY_NAME = fend
BUILD_DIR = .build/release
ENTITLEMENTS = fend.entitlements

.PHONY: build sign clean run debug

# Release build
build:
	swift build -c release

# Debug build
debug:
	swift build

# Ad-hoc code sign with virtualization entitlement
sign: build
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(BINARY_NAME)

# Build + sign in one step
all: sign

# Run the built binary (must be signed first)
run: sign
	$(BUILD_DIR)/$(BINARY_NAME) $(ARGS)

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build

# Show help
help:
	$(BUILD_DIR)/$(BINARY_NAME) --help
