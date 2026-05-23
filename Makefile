.PHONY: install deploy clean
install:
    @echo "Place k3s-install.sh in repo root and run it"
deploy:
    @echo "kubectl apply -f manifests/"
clean:
    @echo "Remove generated artifacts"
