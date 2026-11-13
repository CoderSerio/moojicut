PYTHON ?= python3
RELEASE_VERSION ?= 0.1.0-alpha.1

.DEFAULT_GOAL := build
.NOTPARALLEL:
.PHONY: build dev test smoke release

build:
	$(PYTHON) scripts/native.py build

dev:
	$(PYTHON) scripts/native.py dev

test:
	$(PYTHON) scripts/native.py test

smoke:
	$(PYTHON) scripts/native.py smoke

release:
	$(PYTHON) scripts/native.py release --release-version "$(RELEASE_VERSION)"
