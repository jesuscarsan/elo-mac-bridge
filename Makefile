APP_NAME=EloMacBridge
EXECUTABLE_NAME=elo-mac-bridge
BUILD_DIR=.build/release
APP_BUNDLE=$(APP_NAME).app
CONTENTS_DIR=$(APP_BUNDLE)/Contents
MACOS_DIR=$(CONTENTS_DIR)/MacOS
RESOURCES_DIR=$(CONTENTS_DIR)/Resources

.PHONY: all clean run

all: app

bump-version:
	@current_version=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist); \
	new_version=$$(echo $$current_version | awk -F. -v OFS=. '{$$NF += 1 ; print}'); \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$new_version" Info.plist; \
	echo "Bumped version to $$new_version"

build: bump-version
	swift build -c release

app: build
	mkdir -p $(MACOS_DIR)
	mkdir -p $(RESOURCES_DIR)
	cp $(BUILD_DIR)/$(EXECUTABLE_NAME) $(MACOS_DIR)/
	cp Info.plist $(CONTENTS_DIR)/
	@echo "App Bundle created at $(APP_BUNDLE)"

clean:
	rm -rf .build
	rm -rf $(APP_BUNDLE)

run: app
	@echo "Killing existing instances..."
	@pkill -9 -f "$(EXECUTABLE_NAME)" || true
	open $(APP_BUNDLE)
