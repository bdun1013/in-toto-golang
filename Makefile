
-include .env

#VERSION := $(shell git describe --tags)
#BUILD := $(shell git rev-parse --short HEAD)
PROJECTNAME := in-toto-go

# Go related variables.
#GOBASE := $(shell pwd)
#GOPATH := $(GOBASE)/vendor:$(GOBASE)
#GOBIN := $(GOBASE)/bin
#GOFILES := $(wildcard *.go)

# Use linker flags to provide version/build settings
#LDFLAGS=-ldflags "-X=main.Version=$(VERSION) -X=main.Build=$(BUILD)"

# Make is verbose in Linux. Make it silent.
#MAKEFLAGS += --silent

#Common Certificate Attributes
TRUST_DOMAIN_FQDN := example.com
DEFAULT_BITS := 2048
DEFAULT_MD := sha512
ORGANIZATIONAL_UNIT := example
ORGANIZATION := example
ROOT_DAYS := 3650
INTERMEDIATE_DAYS := 3650
LEAF_DAYS := 1

#Template Location
OPENSSL_TMPL := ./certs/openssl.cnf.tmpl
LAYOUT_TMPL := ./certs/layout.tmpl

build: modules
	@mkdir -p bin
	@go build -o=./bin/in-toto ./cmd/in-toto

modules:
	@go mod tidy

clean: clean-certs clean-test-files
	@rm -rf ./bin

clean-certs:
	@rm ./certs/*.pem ./certs/*.srl ./certs/*.cnf

clean-test-files:
	@rm -rf ./test/tmp
	@rm ./untar.link

generate_layout: leaf_certs
	@mkdir -p ./test/tmp
	$(eval rootid := $(shell ./bin/in-toto key id ./certs/root.cert.pem))
	$(eval rootca := $(shell ./bin/in-toto key layout ./certs/root.cert.pem | sed -e 's/\\n/\\\\n/g'))
	@cat $(LAYOUT_TMPL) | sed -e 's#{{ROOTCA}}#$(rootca)#' -e 's#{{ROOTID}}#$(rootid)#' > ./test/tmp/test.layout

test: go-test test-verify test-run

test-sign: build generate_layout
	@./bin/in-toto sign -f ./test/tmp/test.layout -k ./certs/example.com.layout.key.pem -o ./test/tmp/signed.layout

test-run: build
	#Step 1
	@./bin/in-toto run -n write-code -c ./certs/example.com.write-code.cert.pem -k ./certs/example.com.write-code.key.pem -p ./test/tmp/foo.py -d ./test/tmp -- /bin/sh -c "echo hello > ./test/tmp/foo.py"
	#Step 2
	@./bin/in-toto run -n package -c ./certs/example.com.package.cert.pem -k ./certs/example.com.package.key.pem -m ./test/tmp/foo.py -p ./test/tmp/foo.tar.gz -d ./test/tmp -- tar zcvf ./test/tmp/foo.tar.gz ./test/tmp/foo.py

test-verify: build test-sign test-run
	@./bin/in-toto verify -l ./test/tmp/signed.layout -k ./certs/example.com.layout.cert.pem -i ./certs/example.com.intermediate.cert.pem -d ./test/tmp




spiffe-test-generate-layout:
	@mkdir -p ./test/tmp
	@./test-infra/mint-cert.sh layout
	@mv ./layout-svid.pem ./test/tmp
	@mv ./layout-key.pem ./test/tmp
	@mv ./layout-bundle.pem ./test/tmp
	$(eval rootca := $(shell  awk -v ORS='\\\\n' '1' ./test/tmp/layout-bundle.pem))
	@cat $(LAYOUT_TMPL) | sed -e 's#{{ROOTCA}}#$(rootca)#' > ./test/tmp/spiffe.test.layout

test-spiffe-sign: build spiffe-test-generate-layout
	@./bin/in-toto sign -f ./test/tmp/spiffe.test.layout -k ./test/tmp/layout-key.pem -o ./test/tmp/spiffe.signed.layout





go-test:
	@go test ./...

generate-test-certs: intermediate_cert

root-cert:
	$(call generate_openssl_conf,root)
	#Create Root Key
	@openssl genrsa -out ./certs/root.key.pem
	#Create Root Cert
	@openssl req -subj "/C=/ST=/L=/O=$(ORGANIZATION)/OU=$(ORGANIZATIONAL_UNIT)CN=root/" -days $(ROOT_DAYS) -x509 -new \
	-key "./certs/root.key.pem" -out "./certs/root.cert.pem" \
	-config ./certs/$(TRUST_DOMAIN_FQDN).root.openssl.cnf \
	-extensions v3-root


intermediate_cert: root-cert
	$(call generate_openssl_conf,intermediate)
	#Create intermediate key
	@openssl genrsa -out ./certs/$(TRUST_DOMAIN_FQDN).intermediate.key.pem
	#Generate intermediate CSR
	@openssl req -subj "/C=/ST=/L=/O=$(ORGANIZATION)/OU=$(ORGANIZATIONAL_UNIT)CN=$(TRUST_DOMAIN_FQDN)" -new \
	-key ./certs/$(TRUST_DOMAIN_FQDN).intermediate.key.pem \
	-out ./certs/$(TRUST_DOMAIN_FQDN).intermediate.csr.pem \
	-config ./certs/$(TRUST_DOMAIN_FQDN).intermediate.openssl.cnf \
	-extensions v3-intermediate
	#Sign Intermediate CSR Using Root Certificate
	@openssl x509 -days $(INTERMEDIATE_DAYS) -req \
	-CAcreateserial \
	-CA ./certs/root.cert.pem \
	-CAkey ./certs/root.key.pem \
	-in ./certs/$(TRUST_DOMAIN_FQDN).intermediate.csr.pem \
	-out ./certs/$(TRUST_DOMAIN_FQDN).intermediate.cert.pem \
	-extfile ./certs/$(TRUST_DOMAIN_FQDN).intermediate.openssl.cnf \
	-extensions v3-intermediate
	@openssl verify -CAfile ./certs/root.cert.pem ./certs/$(TRUST_DOMAIN_FQDN).intermediate.cert.pem

leaf_certs: intermediate_cert
	$(call generate_leaf_cert,layout)
	$(call generate_leaf_cert,write-code)
	$(call generate_leaf_cert,package)

define generate_leaf_cert	
	$(call generate_openssl_conf,$(1))
	#Generate leaf signing key
	@openssl genrsa -out ./certs/$(TRUST_DOMAIN_FQDN).$(1).key.pem
	#Generate leaf CSR
	openssl req -new \
	-key ./certs/$(TRUST_DOMAIN_FQDN).$(1).key.pem \
	-out ./certs/$(TRUST_DOMAIN_FQDN).$(1).csr.pem \
	-config ./certs/$(TRUST_DOMAIN_FQDN).$(1).openssl.cnf \
	-extensions v3-leaf
	#Sign leaf CSR Using intermediate Certificate
	@openssl x509 -days $(LEAF_DAYS) -req \
	-CAcreateserial \
	-CA ./certs/$(TRUST_DOMAIN_FQDN).intermediate.cert.pem \
	-CAkey ./certs/$(TRUST_DOMAIN_FQDN).intermediate.key.pem \
	-in ./certs/$(TRUST_DOMAIN_FQDN).$(1).csr.pem \
	-out ./certs/$(TRUST_DOMAIN_FQDN).$(1).cert.pem \
	-extfile ./certs/$(TRUST_DOMAIN_FQDN).$(1).openssl.cnf \
	-extensions v3-leaf
endef

define generate_openssl_conf
	@cat $(OPENSSL_TMPL) | sed -e 's/{{TRUST_DOMAIN_FQDN}}/$(TRUST_DOMAIN_FQDN)/'  | \
	sed -e 's/{{ORGANIZATIONAL_UNIT}}/$(ORGANIZATIONAL_UNIT)/' | \
	sed -e 's/{{ORGANIZATION}}/$(ORGANIZATION)/' | \
	sed -e 's/{{DEFUALT_BITS}}/$(DEFAULT_BITS)/' | \
	sed -e 's/{{DEFAULT_MD}}/$(DEFAULT_MD)/' | \
	sed -e 's/{{SPIFFE_PATH}}/$(1)/' > certs/$(TRUST_DOMAIN_FQDN).$(1).openssl.cnf
endef


.PHONY: help
all: help
help: Makefile
	@echo
	@echo " Choose a command run in in-toto-golang:"
	@echo
	@sed -n 's/^##//p' $< | column -t -s ':' |  sed -e 's/^/ /'
	@echo
