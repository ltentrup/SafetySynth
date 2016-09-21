.PHONY: default debug release test tools all clean distclean

default: debug

debug: tools
	swift build

release: tools
	swift build --configuration release

test:
	swift test

clean:
	swift build --clean

distclean:
	swift build --clean=dist
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
	cd Tools ; hg clone https://bitbucket.org/alanmi/abc abc-hg

