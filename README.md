# Timewarp Enabled Actor for Erlang

[![Build Status](https://travis-ci.org/pulltab/gen_tw.svg?branch=master)](https://travis-ci.org/pulltab/gen_tw)

## Requirements:
* rebar3
* Erlang 17 or newer

## Features:
* OTP friendly
* Handles state rollback and event causality between agents (events/antivents) automatically
* LVT upper bound allows a user to fix simulation within a certain distance from GVT

## Building

```
make
```

## Running Unit Tests

```
make check
```
