UUID := mcp-indicator@rodriguesfas.github.io
ZIP := $(UUID).shell-extension.zip
VENV := venv
PYTHON ?= python3

.PHONY: pack shexli venv clean

pack:
	rm -f $(ZIP)
	if command -v gnome-extensions >/dev/null; then \
		gnome-extensions pack -f \
			--extra-source=detector.js \
			--extra-source=health.js \
			--extra-source=control.js \
			--extra-source=LICENSE \
			--extra-source=COPYING; \
	else \
		zip -q $(ZIP) metadata.json extension.js prefs.js stylesheet.css \
			detector.js health.js control.js LICENSE COPYING \
			schemas/org.gnome.shell.extensions.mcp-indicator.gschema.xml; \
	fi

venv:
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -U pip
	$(VENV)/bin/pip install -U -r requirements-shexli.txt

shexli: pack
	@test -x $(VENV)/bin/shexli || $(MAKE) venv
	$(VENV)/bin/shexli --format json $(ZIP) | tee /tmp/shexli-$(UUID).json
	$(VENV)/bin/python shexli-gate.py /tmp/shexli-$(UUID).json

clean:
	rm -f $(ZIP)
