PYTHON ?= python3
RELEASE_VERSION ?= 0.1.0-alpha.5

.DEFAULT_GOAL := build
.NOTPARALLEL:
.PHONY: build dev test smoke release

build:
	$(PYTHON) scripts/desktop.py build

dev:
	$(PYTHON) scripts/desktop.py dev

test:
	$(PYTHON) scripts/desktop.py test

smoke:
	$(PYTHON) scripts/desktop.py smoke

release:
	$(PYTHON) scripts/desktop.py release --release-version "$(RELEASE_VERSION)"
