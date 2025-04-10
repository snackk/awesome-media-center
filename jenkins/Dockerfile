FROM jenkins/jenkins:lts
USER root
RUN apt-get update
RUN apt -y install ca-certificates-java openjdk-17-jdk
ENV PATH="/usr/lib/jvm/java-17-openjdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
RUN curl -sSL https://get.docker.com/ | sh


#Approach suggested by IA
#FROM jenkins/jenkins:lts
#USER root
#
## Install Docker CLI
#RUN apt-get update && apt-get install -y \
#ca-certificates curl gnupg lsb-release && \
#curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
#echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
#apt-get update && apt-get install -y docker-ce-cli
#
## Add Jenkins user to the Docker group
#RUN usermod -aG docker jenkins
#USER jenkins
