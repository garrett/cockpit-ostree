PACKAGE_NAME := cockpit-ostree
VERSION := $(shell T=$$(git describe 2>/dev/null) || T=1; echo $$T | tr '-' '.')
ifeq ($(TEST_OS),)
TEST_OS = continuous-atomic
endif
export TEST_OS
VM_IMAGE=$(CURDIR)/test/images/$(TEST_OS)
# stamp file to check if/when npm install ran
NODE_MODULES_TEST=package-lock.json
# one example file in dist/ from webpack to check if that already ran
WEBPACK_TEST=dist/index.html

all: $(WEBPACK_TEST)

#
# i18n
#

LINGUAS=$(basename $(notdir $(wildcard po/*.po)))
WEBLATE_REPO=tmp/weblate-repo
WEBLATE_REPO_URL=https://github.com/cockpit-project/cockpit-ostree-weblate.git
WEBLATE_REPO_BRANCH=master

po/POTFILES.js.in:
	mkdir -p $(dir $@)
	find src/ -name '*.js' -o -name '*.jsx' > $@

po/$(PACKAGE_NAME).js.pot: po/POTFILES.js.in
	xgettext --default-domain=cockpit --output=$@ --language=C --keyword= \
		--keyword=_:1,1t --keyword=_:1c,2,2t --keyword=C_:1c,2 \
		--keyword=N_ --keyword=NC_:1c,2 \
		--keyword=gettext:1,1t --keyword=gettext:1c,2,2t \
		--keyword=ngettext:1,2,3t --keyword=ngettext:1c,2,3,4t \
		--keyword=gettextCatalog.getString:1,3c --keyword=gettextCatalog.getPlural:2,3,4c \
		--from-code=UTF-8 --files-from=$^

po/POTFILES.html.in:
	mkdir -p $(dir $@)
	find src -name '*.html' > $@

po/$(PACKAGE_NAME).html.pot: po/POTFILES.html.in $(NODE_MODULES_TEST)
	po/html2po -f $^ -o $@

po/$(PACKAGE_NAME).manifest.pot: $(NODE_MODULES_TEST)
	po/manifest2po src/manifest.json -o $@

po/$(PACKAGE_NAME).pot: po/$(PACKAGE_NAME).html.pot po/$(PACKAGE_NAME).js.pot po/$(PACKAGE_NAME).manifest.pot
	msgcat --sort-output --output-file=$@ $^

# Update translations against current PO template
update-po: po/$(PACKAGE_NAME).pot
	for lang in $(LINGUAS); do \
		msgmerge --output-file=po/$$lang.po po/$$lang.po $<; \
	done

dist/po.%.js: po/%.po $(NODE_MODULES_TEST)
	mkdir -p $(dir $@)
	po/po2json -m po/po.empty.js -o $@.js.tmp $<
	mv $@.js.tmp $@

$(WEBLATE_REPO):
	git clone --depth=1 -b $(WEBLATE_REPO_BRANCH) $(WEBLATE_REPO_URL) $(WEBLATE_REPO)

upload-pot: po/$(PACKAGE_NAME).pot $(WEBLATE_REPO)
	cp ./po/$(PACKAGE_NAME).pot $(WEBLATE_REPO)
	git -C $(WEBLATE_REPO) commit -m "Update source file" -- $(PACKAGE_NAME).pot
	git -C $(WEBLATE_REPO) push

clean-po:
	rm ./po/*.po

download-po: $(WEBLATE_REPO)
	cp $(WEBLATE_REPO)/*.po ./po/

#
# Build/Install/dist
#

%.spec: %.spec.in
	sed -e 's/@VERSION@/$(VERSION)/g' $< > $@

$(WEBPACK_TEST): $(NODE_MODULES_TEST) $(shell find src/ -type f) package.json webpack.config.js $(patsubst %,dist/po.%.js,$(LINGUAS))
	NODE_ENV=$(NODE_ENV) npm run build

clean:
	rm -rf dist/
	[ ! -e $(PACKAGE_NAME).spec.in ] || rm -f $(PACKAGE_NAME).spec

install: $(WEBPACK_TEST)
	mkdir -p $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)
	cp -r dist/* $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)

# this requires a built source tree and avoids having to install anything system-wide
devel-install: $(WEBPACK_TEST)
	mkdir -p ~/.local/share/cockpit
	ln -s `pwd`/dist ~/.local/share/cockpit/$(PACKAGE_NAME)

# when building a distribution tarball, call webpack with a 'production' environment
# we don't ship node_modules for license and compactness reasons; we ship a
# pre-built dist/ (so it's not necessary) and ship packge-lock.json (so that
# node_modules/ can be reconstructed if necessary)
dist-gzip: NODE_ENV=production
dist-gzip: all $(PACKAGE_NAME).spec
	mv node_modules node_modules.release
	touch -r package.json $(NODE_MODULES_TEST)
	touch dist/*
	tar czf $(PACKAGE_NAME)-$(VERSION).tar.gz --transform 's,^,$(PACKAGE_NAME)/,' \
		--exclude $(PACKAGE_NAME).spec.in \
		$$(git ls-files) package-lock.json $(PACKAGE_NAME).spec dist/
	mv node_modules.release node_modules

srpm: dist-gzip $(PACKAGE_NAME).spec
	rpmbuild -bs \
	  --define "_sourcedir `pwd`" \
	  --define "_srcrpmdir `pwd`" \
	  $(PACKAGE_NAME).spec

# this is a noarch build, so local rpm build works fine mostly; the exception
# is continuous-atomic, which does not get along with rpms build on Fedora ≥ 31
rpm: srpm bots
	set -e; srpm=`ls *.src.rpm | head -n1`; \
	if [ "$$TEST_OS" = continuous-atomic ]; then \
	    bots/image-download centos-7; \
	    test/rpmbuild-vm "$$srpm" centos-7; \
	else \
	    test/rpmbuild-local "$$srpm"; \
	fi

# build a VM with locally built rpm installed, cockpit/ws container, and local
# ostree for testing
$(VM_IMAGE): rpm bots
	rm -f $(VM_IMAGE) $(VM_IMAGE).qcow2
	bots/image-customize -v --upload $$(ls $(PACKAGE_NAME)-*.noarch.rpm):/tmp/ \
		--run-command 'rpm -q cockpit-ostree && rpm-ostree override replace /tmp/*.rpm || rpm-ostree install /tmp/*.rpm' \
		$(TEST_OS)
	# building the local tree needs the modified tree from above booted already
	bots/image-customize -v --script $(CURDIR)/test/vm.install $(TEST_OS)

# convenience target for the above
vm: $(VM_IMAGE)
	echo $(VM_IMAGE)

# run the QUnit tests
check-unit: $(NODE_MODULES_TEST)
	npm run test

# run the browser integration tests; skip check for SELinux denials
check: $(NODE_MODULES_TEST) $(VM_IMAGE) test/common check-unit
	TEST_AUDIT_NO_SELINUX=1 test/check-ostree

# checkout Cockpit's bots for standard test VM images and API to launch them
# must be from master, as only that has current and existing images; but testvm.py API is stable
# support CI testing against a bots change
bots:
	git clone --quiet --reference-if-able $${XDG_CACHE_HOME:-$$HOME/.cache}/cockpit-project/bots https://github.com/cockpit-project/bots.git
	if [ -n "$$COCKPIT_BOTS_REF" ]; then git -C bots fetch --quiet --depth=1 origin "$$COCKPIT_BOTS_REF"; git -C bots checkout --quiet FETCH_HEAD; fi
	@echo "checked out bots/ ref $$(git -C bots rev-parse HEAD)"

# checkout Cockpit's test API; this has no API stability guarantee, so check out a stable tag
# when you start a new project, use the latest relese, and update it from time to time
test/common:
	git fetch --depth=1 https://github.com/cockpit-project/cockpit.git 211
	git checkout --force FETCH_HEAD -- test/common
	git reset test/common

$(NODE_MODULES_TEST): package.json
	# if it exists already, npm install won't update it; force that so that we always get up-to-date packages
	rm -f package-lock.json
	# unset NODE_ENV, skips devDependencies otherwise
	env -u NODE_ENV npm install
	env -u NODE_ENV npm prune

.PHONY: all clean install devel-install dist-gzip srpm rpm check check-unit vm update-po
