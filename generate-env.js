// FILE to generate .env
// for now, hardcoded using genesis.json
// TODO use genesis.template.json with data
const fs = require('fs');
const json = JSON.parse(fs.readFileSync('genesis.json'));

fs.writeFileSync('.env', `GETH_BLOCK_TIME=5
GETH_GASPRICE=1000000000
GETH_GENESIS='${JSON.stringify(json)}'
GETH_KEYSTORE_FILENAME=UTC--2023-05-04T10-27-54.443489969Z--f39fd6e51aad88f6f4ce6ab8827279cfffb92266
GETH_KEYSTORE='{"address":"f39fd6e51aad88f6f4ce6ab8827279cfffb92266","crypto":{"cipher":"aes-128-ctr","ciphertext":"a5982ef69eb74b9e2983682f4e9ee5e319e5ad34490896ee495e34bad72a8357","cipherparams":{"iv":"c2ca22a6fac1d3ab309d1e7e482409a5"},"kdf":"scrypt","kdfparams":{"dklen":32,"n":262144,"p":1,"r":8,"salt":"53b601aff894a272fe60ae729229400462f9027ac665ed8dd08634f130413c01"},"mac":"35c6a45bee206fe273cf4a5edb5aa374d3373176090995119250a1d961d3ae34"},"id":"beff5fef-c7bd-4c32-97ce-133018c4d5d7","version":3}'
GETH_KEYSTORE_PASSWORD=testtesttest
GETH_ETHERBASE=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
`);