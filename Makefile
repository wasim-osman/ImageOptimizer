.PHONY: tools build test package clean

tools:
	./scripts/build-tools.sh

build:
	swift build

test: tools
	swift test

package:
	./package.sh

clean:
	rm -rf .build dist .tools
