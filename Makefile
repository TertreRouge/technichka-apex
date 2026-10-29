SHELL := /bin/bash

.PHONY: install-deps requirements syntax api-test

install-deps:
	python3 -m pip install -r requirements.txt

requirements: install-deps
	ansible-galaxy collection install -r requirements.yml

syntax:
	./tests/test_config.sh

api-test:
	./tests/test_api.sh
