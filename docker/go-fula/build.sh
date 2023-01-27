#!/bin/bash

#before runnig following commands run bellow command for enabling push to dockerhub
#docker login --username=smzahraee

git clone https://github.com/functionland/go-fula

docker buildx create --name multiarch --driver docker-container --use

docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t smzahraee/go-fula:latest --push .
