REBAR           := rebar3
REBAR_CONFIG    := rebar.config

APPS_OPT	:= apps=gen_tw

.DEFAULT_GOAL   := all

.PHONY: all
all: deps compile

.PHONY: compile
compile:
	$(REBAR) clean skip_deps=true
	$(REBAR) compile verbose=1

.PHONY: rel
rel: compile
	$(REBAR) generate -f

.PHONY: clean-all
clean-all: clean
	$(REBAR) delete-deps
	rm -f $(REBAR) $(REBAR_CONFIG_NEW) $(REBAR_BOOTSTRAP)
	mv $(REBAR_CONFIG_O) $(REBAR_CONFIG)

.PHONY: clean
clean:
	$(REBAR) clean

.PHONY: test
test: eunit

.PHONY: check
check: eunit

.PHONY: eunit
eunit:  rebar.config
	$(REBAR) eunit -v --dir="src,test"

.PHONY: deps
deps:
	$(REBAR) deps

.PHONY: shell
shell:
	$(REBAR) shell

.PHONY: doc
doc:
	cd doc && make all
