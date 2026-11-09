#!/bin/sh
# Builds a throwaway chain shaped like Apple's (P-384 root and intermediate, P-256 leaf, Apple's
# marker extensions) for test/apple.test.ts. Output goes to $1.
set -eu
out="$1"; mkdir -p "$out"; cd "$out"
openssl ecparam -name secp384r1 -genkey -noout -out root.key
openssl req -x509 -new -key root.key -sha384 -days 30 -subj "/CN=Test Root" -out root.pem
openssl ecparam -name secp384r1 -genkey -noout -out int.key
openssl req -new -key int.key -subj "/CN=Test WWDR" -out int.csr
printf "basicConstraints=critical,CA:true\n1.2.840.113635.100.6.2.1=ASN1:NULL\n" > int.ext
openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -sha384 -days 30 -extfile int.ext -out int.pem
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
openssl req -new -key leaf.key -subj "/CN=Test StoreKit" -out leaf.csr
printf "1.2.840.113635.100.6.11.1=ASN1:NULL\n" > leaf.ext
openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial -sha384 -days 30 -extfile leaf.ext -out leaf.pem
openssl pkcs8 -topk8 -nocrypt -in leaf.key -out leaf.p8
