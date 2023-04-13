#!/bin/bash

JSON_FILE="All-instances.json"
TOTAL_INSTANCES=$(jq 'length' $JSON_FILE)

for ((i = 0; i < TOTAL_INSTANCES; i++)); do
  INSTANCE=$(jq -r ".[$i].instance" $JSON_FILE)
  IP=$(jq -r ".[$i].ip" $JSON_FILE)

  cat > ${INSTANCE}-csr.json <<EOF
{
  "CN": "system:node:${INSTANCE}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "FR",
      "L": "Paris",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Ile-de-France"
    }
  ]
}
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname=${INSTANCE},${IP}, \
    -profile=kubernetes \
    ${INSTANCE}-csr.json | cfssljson -bare ${INSTANCE}
done

