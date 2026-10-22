#!/bin/sh
# Writes Config/Cloud.secrets.xcconfig from .env (CUE_API_URL, CUE_API_TOKEN). Never committed.
# xcconfig treats // as a comment, so the URL's scheme separator is written as /$()/.
set -eu
cd "$(dirname "$0")/.."
dotenvx run -q -f .env -- sh -c 'printf "CUE_API_URL = %s\nCUE_API_TOKEN = %s\n" "$(printf %s "$CUE_API_URL" | sed "s#//#/\$()/#")" "$CUE_API_TOKEN"' > Config/Cloud.secrets.xcconfig
echo "wrote Config/Cloud.secrets.xcconfig"
