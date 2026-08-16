# NoPeek — Makefile (no Xcode required; Command Line Tools only)
#
# Common targets:
#   make run                build + sign + open the app (ALWAYS launch via `open`, so TCC and
#                           notifications are attributed to the bundle, not a raw binary)
#   make bundle             compile + assemble build/NoPeek.app + codesign
#   make cert               ONE-TIME: create the self-signed "NoPeek Dev" codesigning certificate
#   make test               run NoPeekCore unit tests via SwiftPM
#   make log                stream the app's structured logs
#   make reset-permissions  reset TCC camera/notification grants to retest first-run flow
#   make adhoc              ad-hoc signed build (TCC will re-prompt on EVERY rebuild — dev fallback)
#   make clean

APP_NAME      := NoPeek
BUNDLE_ID     := com.nopeek.NoPeek
BUILD_DIR     := build
APP_DIR       := $(BUILD_DIR)/$(APP_NAME).app
SDK           := $(shell xcrun --sdk macosx --show-sdk-path)
TARGET        := arm64-apple-macos14.0
SWIFT_VERSION := 6
CERT_NAME     ?= NoPeek Dev

SOURCES := $(shell find Sources -name '*.swift' | sort)
BINARY  := $(BUILD_DIR)/$(APP_NAME)

.PHONY: all bundle run clean cert adhoc log test reset-permissions
all: bundle

$(BINARY): $(SOURCES) Makefile
	@mkdir -p $(BUILD_DIR)
	swiftc -O -sdk $(SDK) -target $(TARGET) -swift-version $(SWIFT_VERSION) \
		-module-name $(APP_NAME) $(SOURCES) -o $(BINARY)

bundle: $(BINARY)
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp $(BINARY) "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	@test -f Resources/alert.aiff && cp Resources/alert.aiff "$(APP_DIR)/Contents/Resources/" || true
	codesign --force --sign "$(CERT_NAME)" --identifier $(BUNDLE_ID) --timestamp=none "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

# Ad-hoc signed build. WARNING: the designated requirement embeds the cdhash, which changes
# every recompile — macOS TCC will ask for camera permission again after every build.
adhoc:
	$(MAKE) bundle CERT_NAME=-

# `open` alone would re-activate a stale running instance instead of launching the
# fresh binary — kill any running copy first.
run: bundle
	-@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null
	@sleep 0.3
	open "$(APP_DIR)"

clean:
	rm -rf $(BUILD_DIR) .build

TEST_SOURCES := $(shell find Sources/NoPeekCore Tests -name '*.swift' | sort)
# XCTest ships only with full Xcode (absent from CLT), so tests are a tiny assertion-based
# runner compiled straight with swiftc — same effect, zero extra tooling.
test:
	@mkdir -p $(BUILD_DIR)
	swiftc -O -sdk $(SDK) -target $(TARGET) -module-name NoPeekCoreTests $(TEST_SOURCES) -o $(BUILD_DIR)/NoPeekCoreTests
	./$(BUILD_DIR)/NoPeekCoreTests

log:
	/usr/bin/log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --info --debug

reset-permissions:
	tccutil reset Camera $(BUNDLE_ID)
	-tccutil reset UserNotifications $(BUNDLE_ID)

# ONE-TIME: self-signed codesigning certificate.
# Why this matters: TCC keys permission grants to the code's designated requirement. With a
# stable certificate the requirement anchors on the cert identity, so the camera grant
# survives rebuilds. `security` has no create-identity on this machine, so we mint the cert
# with openssl and import it. Gotchas handled here (verified on macOS 26):
#   - openssl 3.x default p12 (SHA-256 MAC/PBES2) is rejected by `security import`
#     ("MAC verification failed") → export with -legacy providers.
#   - `-A` lets codesign use the key without a keychain prompt (fine for a local,
#     never-distributed dev cert).
#   - `find-identity -v` hides the cert (self-signed ⇒ not trusted); that is cosmetic,
#     codesign signs with it anyway and the requirement anchors on the leaf hash.
cert:
	@if security find-certificate -c "$(CERT_NAME)" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then \
		echo "Certificate '$(CERT_NAME)' already exists — nothing to do"; \
	else \
		TMP=$$(mktemp -d); \
		printf '[ req ]\ndistinguished_name = dn\nx509_extensions = codesign\nprompt = no\n[ dn ]\nCN = %s\n[ codesign ]\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = critical, codeSigning\nbasicConstraints = critical, CA:false\n' "$(CERT_NAME)" > "$$TMP/cert.cnf"; \
		openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$$TMP/cert.cnf" \
			-keyout "$$TMP/key.pem" -out "$$TMP/cert.pem" 2>/dev/null; \
		openssl pkcs12 -export -legacy -provider legacy -provider default \
			-passout pass:nopeek -out "$$TMP/dev.p12" -inkey "$$TMP/key.pem" -in "$$TMP/cert.pem"; \
		security import "$$TMP/dev.p12" -k ~/Library/Keychains/login.keychain-db -P "nopeek" -A; \
		rm -rf "$$TMP"; \
		echo "Self-signed certificate '$(CERT_NAME)' installed into the login keychain."; \
	fi
