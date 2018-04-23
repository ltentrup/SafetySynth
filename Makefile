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
Tools/abc: Tools/abc-hg/abc
	cp Tools/abc-hg/abc Tools/abc

Tools/abc-hg/abc: Tools/abc-hg
	make -C Tools/abc-hg

Tools/abc-hg: Tools/.f
	cd Tools ; git clone https://github.com/berkeley-abc/abc.git abc-hg

