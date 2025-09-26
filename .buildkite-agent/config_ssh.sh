if [[ -z "$1" ]]; then
  echo "Usage: $0 <email_for_ssh_key>"
  exit 1
fi

mkdir -p .ssh
cd .ssh || exit 1

ssh-keygen -t ed25519 -C "$1" -f ./id_ed25519 -N ''
chmod 600 ./id_ed25519

ssh-keyscan -t rsa,ecdsa,ed25519 github.com > ./known_hosts

echo "Public SSH key (add this to your GitHub account or repo deploy keys):"
cat ./id_ed25519.pub

echo "adding SSH config..."
echo "Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  PubkeyAuthentication yes
  StrictHostKeyChecking yes" > config

echo "Testing SSH connection..."
ssh -T git@github.com
