FROM maven:3.9.9-eclipse-temurin-17 AS builder
WORKDIR /workspace

COPY pom.xml mvnw ./
COPY .mvn .mvn
COPY src src

RUN mvn -B -DskipTests package

FROM eclipse-temurin:17-jre
WORKDIR /work

COPY --from=builder /workspace/target/quarkus-app/lib/ /work/lib/
COPY --from=builder /workspace/target/quarkus-app/*.jar /work/
COPY --from=builder /workspace/target/quarkus-app/app/ /work/app/
COPY --from=builder /workspace/target/quarkus-app/quarkus/ /work/quarkus/

EXPOSE 8080
ENTRYPOINT ["java","-Dquarkus.http.host=0.0.0.0","-jar","/work/quarkus-run.jar"]
