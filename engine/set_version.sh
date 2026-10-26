#!/bin/sh
# Copies engine/VERSION into the engine's source (the macOS app reads it from its Info.plist).
cd "$(dirname "$0")"
printf '// Written from engine/VERSION by engine/set_version.sh: do not edit by hand.\nlet engineVersion = "%s"\n' "$(cat VERSION)" > Sources/synccli/Version.swift
