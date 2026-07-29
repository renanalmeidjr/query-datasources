package io.github.renanalmeidjr.harness;

import com.fasterxml.jackson.annotation.JsonAlias;
import io.agroal.api.AgroalDataSource;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

@Path("/")
@ApplicationScoped
@Produces(MediaType.APPLICATION_JSON)
public class TestResource {
    private static final Logger LOG = Logger.getLogger(TestResource.class);

    @Inject
    AgroalDataSource dataSource;

    @Inject
    MeterRegistry meterRegistry;

    @ConfigProperty(name = "harness.cache-sync.enabled", defaultValue = "false")
    boolean cacheSyncEnabled;

    @ConfigProperty(name = "harness.cache-sync.interval-ms", defaultValue = "100")
    long cacheSyncIntervalMs;

    @ConfigProperty(name = "harness.cache-sync.session-id", defaultValue = "session-000001")
    String cacheSyncSessionId;

    private final AtomicLong totalConnectionAcquireNanos = new AtomicLong(0L);
    private Counter selectCounter;
    private Counter updateCounter;
    private ScheduledExecutorService cacheSyncScheduler;

    @PostConstruct
    void init() {
        selectCounter = meterRegistry.counter("harness_select_total");
        updateCounter = meterRegistry.counter("harness_update_total");

        Gauge.builder("agroal_pool_active_count", dataSource, ds -> ds.getMetrics().activeCount()).register(meterRegistry);
        Gauge.builder("agroal_pool_available_count", dataSource, ds -> ds.getMetrics().availableCount()).register(meterRegistry);
        Gauge.builder("agroal_pool_total_creation_time", totalConnectionAcquireNanos, AtomicLong::doubleValue)
                .baseUnit("nanoseconds")
                .register(meterRegistry);

        if (cacheSyncEnabled) {
            cacheSyncScheduler = Executors.newSingleThreadScheduledExecutor();
            cacheSyncScheduler.scheduleAtFixedRate(this::runCacheSyncUpdate, cacheSyncIntervalMs, cacheSyncIntervalMs, TimeUnit.MILLISECONDS);
            LOG.infof("Cache sync simulation enabled with interval=%dms", cacheSyncIntervalMs);
        }
    }

    @PreDestroy
    void stop() {
        if (cacheSyncScheduler != null) {
            cacheSyncScheduler.shutdownNow();
        }
    }

    @GET
    @Path("/health")
    public Map<String, String> health() {
        return Map.of("status", "UP");
    }

    @GET
    @Path("/test/session/{sessionId}")
    public Map<String, Object> getSession(@PathParam("sessionId") String sessionId) {
        try {
            return withTransaction(connection -> {
                String sql = "SELECT id, user_id, realm_id, client_id, last_activity_time, created_at FROM offline_user_session WHERE id = ?";
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    statement.setString(1, sessionId);
                    try (ResultSet rs = statement.executeQuery()) {
                        if (!rs.next()) {
                            throw new NotFoundException("Session not found: " + sessionId);
                        }
                        selectCounter.increment();
                        Map<String, Object> response = new LinkedHashMap<>();
                        response.put("id", rs.getString("id"));
                        response.put("userId", rs.getString("user_id"));
                        response.put("realmId", rs.getString("realm_id"));
                        response.put("clientId", rs.getString("client_id"));
                        response.put("lastActivityTime", rs.getLong("last_activity_time"));
                        response.put("createdAt", rs.getLong("created_at"));
                        return response;
                    }
                }
            });
        } catch (SQLException e) {
            throw asServerError(e);
        }
    }

    @PUT
    @Path("/test/session/{sessionId}")
    @Consumes(MediaType.APPLICATION_JSON)
    public Map<String, Object> updateSession(@PathParam("sessionId") String sessionId, UpdateSessionRequest request) {
        long timestamp = resolveTimestamp(request);
        try {
            Integer rows = withTransaction(connection -> {
                String sql = "UPDATE offline_user_session SET last_activity_time = ? WHERE id = ?";
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    statement.setLong(1, timestamp);
                    statement.setString(2, sessionId);
                    int updated = statement.executeUpdate();
                    if (updated == 0) {
                        throw new NotFoundException("Session not found: " + sessionId);
                    }
                    updateCounter.increment();
                    return updated;
                }
            });
            return Map.of("id", sessionId, "rowsAffected", rows, "lastActivityTime", timestamp);
        } catch (SQLException e) {
            throw asServerError(e);
        }
    }

    @GET
    @Path("/test/user/{userId}")
    public Map<String, Object> getUser(@PathParam("userId") String userId) {
        try {
            return withTransaction(connection -> {
                String sql = "SELECT id, realm_id, username, email, created_at FROM [user] WHERE id = ?";
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    statement.setString(1, userId);
                    try (ResultSet rs = statement.executeQuery()) {
                        if (!rs.next()) {
                            throw new NotFoundException("User not found: " + userId);
                        }
                        selectCounter.increment();
                        Map<String, Object> response = new LinkedHashMap<>();
                        response.put("id", rs.getString("id"));
                        response.put("realmId", rs.getString("realm_id"));
                        response.put("username", rs.getString("username"));
                        response.put("email", rs.getString("email"));
                        response.put("createdAt", rs.getLong("created_at"));
                        return response;
                    }
                }
            });
        } catch (SQLException e) {
            throw asServerError(e);
        }
    }

    private long resolveTimestamp(UpdateSessionRequest request) {
        if (request == null || request.lastActivity == null) {
            return Instant.now().toEpochMilli();
        }
        return request.lastActivity < 1_000_000_000_000L ? request.lastActivity * 1000L : request.lastActivity;
    }

    private void runCacheSyncUpdate() {
        long timestamp = Instant.now().toEpochMilli();
        try {
            withTransaction(connection -> {
                String sql = "UPDATE offline_user_session SET last_activity_time = ? WHERE id = ?";
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    statement.setLong(1, timestamp);
                    statement.setString(2, cacheSyncSessionId);
                    statement.executeUpdate();
                }
                return null;
            });
        } catch (Exception e) {
            LOG.debugf("Cache sync update skipped: %s", e.getMessage());
        }
    }

    private <T> T withTransaction(SqlWork<T> work) throws SQLException {
        long acquireStartedAt = System.nanoTime();
        try (Connection connection = dataSource.getConnection()) {
            totalConnectionAcquireNanos.addAndGet(System.nanoTime() - acquireStartedAt);
            connection.setAutoCommit(false);
            try {
                T result = work.execute(connection);
                connection.commit();
                return result;
            } catch (NotFoundException e) {
                connection.rollback();
                throw e;
            } catch (Exception e) {
                connection.rollback();
                throw (e instanceof SQLException) ? (SQLException) e : new SQLException("Transaction execution failed", e);
            }
        }
    }

    private WebApplicationException asServerError(SQLException e) {
        LOG.error("Database operation failed", e);
        return new WebApplicationException("Database operation failed", e, Response.Status.INTERNAL_SERVER_ERROR);
    }

    @FunctionalInterface
    interface SqlWork<T> {
        T execute(Connection connection) throws Exception;
    }

    public static class UpdateSessionRequest {
        @JsonAlias("last_activity")
        public Long lastActivity;
    }
}
