CREATE TABLE realm (
    id VARCHAR(36) PRIMARY KEY,
    name NVARCHAR(255) NOT NULL UNIQUE,
    display_name NVARCHAR(255),
    created_at BIGINT
);
CREATE INDEX idx_realm_name ON realm(name);

CREATE TABLE client (
    id VARCHAR(36) PRIMARY KEY,
    realm_id VARCHAR(36) NOT NULL,
    client_id NVARCHAR(255) NOT NULL,
    name NVARCHAR(255),
    created_at BIGINT,
    FOREIGN KEY (realm_id) REFERENCES realm(id)
);
CREATE INDEX idx_client_client_id ON client(client_id);
CREATE INDEX idx_client_realm_id ON client(realm_id);

CREATE TABLE [user] (
    id VARCHAR(36) PRIMARY KEY,
    realm_id VARCHAR(36) NOT NULL,
    username NVARCHAR(255) NOT NULL,
    email NVARCHAR(255),
    created_at BIGINT,
    FOREIGN KEY (realm_id) REFERENCES realm(id)
);
CREATE UNIQUE INDEX idx_user_username ON [user](username);
CREATE INDEX idx_user_realm_id ON [user](realm_id);

CREATE TABLE offline_user_session (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL,
    realm_id VARCHAR(36) NOT NULL,
    client_id VARCHAR(36) NOT NULL,
    offline_flag BIT,
    data NVARCHAR(MAX),
    last_activity_time BIGINT,
    created_at BIGINT,
    FOREIGN KEY (user_id) REFERENCES [user](id),
    FOREIGN KEY (realm_id) REFERENCES realm(id),
    FOREIGN KEY (client_id) REFERENCES client(id)
);
CREATE INDEX idx_session_user_id ON offline_user_session(user_id);
CREATE INDEX idx_session_realm_id ON offline_user_session(realm_id);
CREATE INDEX idx_session_offline_flag ON offline_user_session(offline_flag);
