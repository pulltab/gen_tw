THIS_MAKEFILE   := $(lastword $(MAKEFILE_LIST))
MAKEFILE_DIR    := $(abspath $(addprefix $(CURDIR)/,$(dir $(THIS_MAKEFILE))))
D               := $(MAKEFILE_DIR)
DEPS_DIR        := $(D)/deps
PRIV_DIR        := $(D)/priv
REBAR           := rebar
REBAR_CONFIG    := rebar.config
REBAR_CONFIG_NEW := $(REBAR_DIR)/rebar.config.new
REBAR_CONFIG_O  := $(REBAR_DIR)/rebar.config.orig
REBAR_BOOTSTRAP := $(REBAR_DIR)/bootstrap.sh

ERL_FLAGS_A     := # +A 16
ERL_FLAGS_a     := # +a 8192
ERL_FLAGS_K     := # +K false
ERL_FLAGS_P     := # +P 1048576 # +P 134217727
ERL_FLAGS_Q     := # -env ERL_MAX_PORTS 65536 # 1048576 # 134217727 # +Q 134217727
ERL_FLAGS_rg    := # +rg 1 # 1024/64
ERL_FLAGS       := "$(ERL_FLAGS_A) $(ERL_FLAGS_a) $(ERL_FLAGS_K) $(ERL_FLAGS_P) $(ERL_FLAGS_Q) $(ERL_FLAGS_rg)"

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
	$(REBAR) eunit $(APPS_OPT) $(SUITES:%=suites=%) $(TESTS:%=tests=%)

.PHONY: deps
deps: get-deps

.PHONY: get-deps
get-deps:
	$(REBAR) get-deps

.PHONY: update-deps
update-deps:
	$(REBAR) update-deps

.PHONY: doc
doc:
	cd doc && make all

.PHONY: xref
xref: $(REBAR_CONFIG)
	$(REBAR) xref $(APPS_OPT)
