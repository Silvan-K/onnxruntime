#!/bin/bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

# Get directory this script is in
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
OS=$(uname -s)

if [ "$OS" = "Darwin" ]; then
    DIR_OS="MacOS"
else
    DIR_OS="Linux"
fi

if [[ "$*" == *"--ios"* ]]; then
    DIR_OS="iOS"
elif [[ "$*" == *"--android"* ]]; then
    DIR_OS="Android"
fi

# Build and create python wheel
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
bake run -t //Groq/Tools:hempy -- hempy $DIR/tools/ci_build/build.py --build_dir $DIR/build/$DIR_OS  --parallel=6 --build_wheel --config RelWithDebInfo --build_shared_lib --skip_tests
cd build/Linux/RelWithDebInfo && bake run -t //Groq/Tools:hempy -- hempy ../../../setup.py bdist_wheel

# Upload wheel and modify path to wheel in nix file
ORT_NIX_PATH=$(nix add-to-store $(find ./ -name "onnxruntime*.whl"))
bake upload $ORT_NIX_PATH
sed -i 's%/nix.*whl%'"$ORT_NIX_PATH"'%' $(git rev-parse --show-toplevel)/bake/nix/global/uncached-full/groqpkgs/py/onnxruntime-whl.nix 
