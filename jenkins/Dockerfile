FROM jenkins/jenkins:lts
USER root
RUN apt-get update && apt-get install -y wget tar
RUN wget https://download.java.net/java/GA/jdk21.0.2/f2283984656d49d69e91c558476027ac/13/GPL/openjdk-21.0.2_linux-x64_bin.tar.gz
RUN mkdir -p /usr/lib/jvm && tar -xzf openjdk-21.0.2_linux-x64_bin.tar.gz -C /usr/lib/jvm && mv /usr/lib/jvm/jdk-21.0.2 /usr/lib/jvm/java-21-openjdk-amd64 && rm openjdk-21.0.2_linux-x64_bin.tar.gz
ENV JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
ENV PATH="$JAVA_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
RUN curl -sSL https://get.docker.com/ | sh
