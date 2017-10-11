#!/bin/bash -e
# Copyright (c) 2017 by AIS
# Copyright (c) 2015 by Roderick W. Smith
# Licensed under the terms of the GPL v3

echo -n "Enter a Common Name to embed in the keys: "
read NAME

mkdir -p keys

git submodule update --init efitools
cd efitools

make cert-to-efi-sig-list
make sign-efi-sig-list

openssl req -new -x509 -newkey rsa:2048 -subj "/CN=$NAME PK/" -keyout PK.key -out PK.crt -days 3650 -nodes -sha256
openssl req -new -x509 -newkey rsa:2048 -subj "/CN=$NAME KEK/" -keyout KEK.key -out KEK.crt -days 3650 -nodes -sha256
openssl req -new -x509 -newkey rsa:2048 -subj "/CN=$NAME DB/" -keyout DB.key -out DB.crt -days 3650 -nodes -sha256
openssl req -new -x509 -newkey rsa:2048 -subj "/CN=$NAME SHIM/" -keyout SHIM.key -out SHIM.crt -days 3650 -nodes -sha256
openssl x509 -in PK.crt -out PK.cer -outform DER
openssl x509 -in KEK.crt -out KEK.cer -outform DER
openssl x509 -in DB.crt -out DB.cer -outform DER
openssl x509 -in SHIM.crt -out SHIM.cer -outform DER

if ls myGUID.txt 1 > /dev/null 2>&1; then
    GUID=`cat myGUID.txt`
else
    GUID=`python -c 'import uuid; print(str(uuid.uuid1()))'`
    echo $GUID > myGUID.txt
fi

./cert-to-efi-sig-list -g $GUID PK.crt PK.esl
./cert-to-efi-sig-list -g $GUID KEK.crt KEK.esl
./cert-to-efi-sig-list -g $GUID DB.crt DB.esl
touch noPK.esl

./sign-efi-sig-list -t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" -k PK.key -c PK.crt PK PK.esl PK.auth
./sign-efi-sig-list -t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" -k PK.key -c PK.crt KEK KEK.esl KEK.auth
./sign-efi-sig-list -t "$(date --date='1 second' +'%Y-%m-%d %H:%M:%S')" -k KEK.key -c KEK.crt db DB.esl DB.auth

# The noPK.auth file needs to have a later timestamp then PK otherwise some firmwares will reject it
./sign-efi-sig-list -t "$(date --date='2 second' +'%Y-%m-%d %H:%M:%S')" -k PK.key -c PK.crt PK noPK.esl noPK.auth

chmod 0600 *.key

make LockDown.efi
sbsign --key DB.key --cert DB.crt --output LockDown-signed.efi LockDown.efi 2>/dev/null

mv *.key ../keys
mv *.crt ../keys
mv *.esl ../keys
mv *.auth ../keys
mv myGUID.txt ../keys
mv LockDown-signed.efi ../keys

cd ..
