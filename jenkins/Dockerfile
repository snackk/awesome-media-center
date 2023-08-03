FROM jenkins/jenkins:lts
USER root
RUN apt-get update
RUN apt -y install ca-certificates-java openjdk-17-jdk
ENV PATH="/usr/lib/jvm/java-17-openjdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
RUN curl -sSL https://get.docker.com/ | sh
