#!/bin/bash
set -e

bundle=$1

# The passphrase comes from $SPRINKLES_PASS so it never shows up in argv
if [ -z "$SPRINKLES_PASS" ]; then
    echo "SPRINKLES_PASS is not set" >&2
    exit 1
fi

mkdir -p Certs && cd Certs

root_conf="$bundle/rootCA.csr.conf"
cert_conf="$bundle/sprinkles.csr.conf"
ext="$bundle/v3.ext"
ca_key="ca_key.pem"
ca_cert="ca_cert.pem"
ca_der="ca.der"
csr="sprinkles.csr"
key="key.pem"
cert="cert.pem"
p12="identity.p12"

echo "--- Generate root CA key ------------------------"
/usr/bin/openssl genrsa -des3 \
    -passout env:SPRINKLES_PASS \
    -out $ca_key 2048
echo "-------------------------------------------------"

echo "- Generate root CA certificate ------------------"
/usr/bin/openssl req -x509 -new -nodes \
    -key $ca_key \
    -sha256 -days 825 \
    -out $ca_cert \
    -passin env:SPRINKLES_PASS \
    -config $root_conf \
    -extensions v3_ca
echo "-------------------------------------------------"

echo "- Convert root CA to .der -----------------------"
/usr/bin/openssl x509 \
    -outform der \
    -in $ca_cert \
    -out $ca_der
echo "-------------------------------------------------"

echo "- Create localhost key --------------------------"
/usr/bin/openssl req -new -sha256 -nodes \
    -out $csr \
    -newkey rsa:2048 \
    -keyout $key \
    -config $cert_conf
echo "-------------------------------------------------"

echo "- Create localhost certificate based on root CA -"
/usr/bin/openssl x509 -req \
    -in $csr \
    -CA $ca_cert -CAkey $ca_key -CAcreateserial \
    -out $cert \
    -days 825 \
    -sha256 -extfile $ext \
    -passin env:SPRINKLES_PASS
echo "-------------------------------------------------"

echo "- Combine and convert to pkcs12 -----------------"
/usr/bin/openssl pkcs12 -export \
    -out $p12 \
    -in $cert  \
    -inkey $key \
    -passout env:SPRINKLES_PASS
echo "-------------------------------------------------"

echo "- Remove root CA key ----------------------------"
# Nothing needs it after signing; regenerating recreates everything
rm -f $ca_key
echo "-------------------------------------------------"

echo "2" > version
