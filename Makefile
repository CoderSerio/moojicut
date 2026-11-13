PYTHON ?= python3

.DEFAULT_GOAL := build
.NOTPARALLEL:
.PHONY: build dev test smoke

build:
	$(PYTHON) scripts/native.py build

dev:
	$(PYTHON) scripts/native.py dev

test:
	$(PYTHON) scripts/native.py test

smoke:
	$(PYTHON) scripts/native.py smoke
