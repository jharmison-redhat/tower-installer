FROM docker.io/redhat/ubi8

COPY requirements.txt requirements.yml LICENSE /installer/
WORKDIR /installer

RUN mkdir -p /installer/downloaded \
 && dnf -y install \
    python39-pip \
    python39-setuptools \
    python39-wheel \
 && curl -Lo- https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz | tar xvzf - -C /usr/local/bin \
 && python3.9 -m pip install -r requirements.txt \
 && gpg --keyserver pool.sks-keyservers.net --recv-keys AC48AC71DA695CA15F2D39C4B84E339C442667A9 \
 && ansible-galaxy collection install -p collections -r requirements.yml

COPY src /installer

ENTRYPOINT ["/usr/local/bin/ansible-playbook", "/installer/main.yml"]
