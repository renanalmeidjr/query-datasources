package io.github.renanalmeidjr.harness;

import io.agroal.api.AgroalDataSource;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;

import java.sql.Connection;
import java.sql.Statement;
import java.util.Map;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.is;
import static org.hamcrest.Matchers.notNullValue;

@QuarkusTest
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class TestResourceTest {
    @Inject
    AgroalDataSource dataSource;

    @BeforeAll
    void initSchema() throws Exception {
        try (Connection connection = dataSource.getConnection(); Statement stmt = connection.createStatement()) {
            stmt.execute("CREATE TABLE realm (id VARCHAR(36) PRIMARY KEY, name NVARCHAR(255) NOT NULL UNIQUE, display_name NVARCHAR(255), created_at BIGINT)");
            stmt.execute("CREATE TABLE client (id VARCHAR(36) PRIMARY KEY, realm_id VARCHAR(36) NOT NULL, client_id NVARCHAR(255) NOT NULL, name NVARCHAR(255), created_at BIGINT)");
            stmt.execute("CREATE TABLE [user] (id VARCHAR(36) PRIMARY KEY, realm_id VARCHAR(36) NOT NULL, username NVARCHAR(255) NOT NULL, email NVARCHAR(255), created_at BIGINT)");
            stmt.execute("CREATE TABLE offline_user_session (id VARCHAR(36) PRIMARY KEY, user_id VARCHAR(36) NOT NULL, realm_id VARCHAR(36) NOT NULL, client_id VARCHAR(36) NOT NULL, offline_flag BOOLEAN, data NVARCHAR(4000), last_activity_time BIGINT, created_at BIGINT)");

            stmt.execute("INSERT INTO realm (id, name, display_name, created_at) VALUES ('realm-1','realm-1','Realm 1',1)");
            stmt.execute("INSERT INTO client (id, realm_id, client_id, name, created_at) VALUES ('client-1','realm-1','client-1','Client 1',1)");
            stmt.execute("INSERT INTO [user] (id, realm_id, username, email, created_at) VALUES ('user-1','realm-1','user1','user1@test.local',1)");
            stmt.execute("INSERT INTO offline_user_session (id, user_id, realm_id, client_id, offline_flag, data, last_activity_time, created_at) VALUES ('session-1','user-1','realm-1','client-1',0,'{}',1,1)");
        }
    }

    @Test
    void testHealthEndpoint() {
        given()
                .when().get("/health")
                .then()
                .statusCode(200)
                .body("status", is("UP"));
    }

    @Test
    void testGetSessionEndpoint() {
        given()
                .when().get("/test/session/session-1")
                .then()
                .statusCode(200)
                .body("id", is("session-1"))
                .body("userId", is("user-1"));
    }

    @Test
    void testUpdateSessionEndpoint() {
        given()
                .contentType("application/json")
                .body(Map.of("lastActivity", 1_723_001_234_000L))
                .when().put("/test/session/session-1")
                .then()
                .statusCode(200)
                .body("rowsAffected", is(1))
                .body("lastActivityTime", is(1_723_001_234_000L));
    }

    @Test
    void testGetUserEndpoint() {
        given()
                .when().get("/test/user/user-1")
                .then()
                .statusCode(200)
                .body("id", is("user-1"))
                .body("username", is("user1"));
    }

    @Test
    void testMetricsEndpoint() {
        given()
                .when().get("/metrics")
                .then()
                .statusCode(200)
                .body(notNullValue());
    }
}