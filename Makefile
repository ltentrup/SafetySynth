.PHONY: default debug release test tools all clean distclean

default: debug

debug: tools
	swift build

release: tools
	swift build --configuration release -Xcc -O3 -Xcc -DNDEBUG -Xswiftc -Ounchecked

test:
	swift test

clean:
	swift package clean

distclean:
	swift package reset
	rm -rf Tools

tools: Tools/abc

Tools/.f:
	mkdir -p Tools
	touch Tools/.f

# abc
Tools/abc: Tools/abc-build
	cd Tools ; mv abc build-abc ; cp build-abc/abc .

Tools/abc-build: Tools/abc-git
	make -C Tools/abc

Tools/abc-git: Tools/.f
	cd Tools ; git clone https://github.com/berkeley-abc/abc 

