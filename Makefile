APP_NAME=EloMacBridge
EXECUTABLE_NAME=elo-mac-bridge
BUILD_DIR=.build/release
APP_BUNDLE=$(APP_NAME).app
CONTENTS_DIR=$(APP_BUNDLE)/Contents
MACOS_DIR=$(CONTENTS_DIR)/MacOS
RESOURCES_DIR=$(CONTENTS_DIR)/Resources

.PHONY: all clean run

all: app

build:
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
	open $(APP_BUNDLE)
