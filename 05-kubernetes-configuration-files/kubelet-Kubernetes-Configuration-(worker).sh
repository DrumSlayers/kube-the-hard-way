#!/bin/bash

JSON_FILE="All-instances.json"
TOTAL_INSTANCES=$(jq 'length' $JSON_FILE)

for ((i = 0; i < TOTAL_INSTANCES; i++)); do
  INSTANCE=$(jq -r ".[$i].instance" $JSON_FILE)

  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://192.168.10.28:6443 \
    --kubeconfig=${INSTANCE}.kubeconfig

  kubectl config set-credentials system:node:${INSTANCE} \
    --client-certificate=${INSTANCE}.pem \
    --client-key=${INSTANCE}-key.pem \
    --embed-certs=true \
    --kubeconfig=${INSTANCE}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${INSTANCE} \
    --kubeconfig=${INSTANCE}.kubeconfig

  kubectl config use-context default --kubeconfig=${INSTANCE}.kubeconfig
done

