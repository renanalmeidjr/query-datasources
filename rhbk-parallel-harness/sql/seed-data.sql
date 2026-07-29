SET NOCOUNT ON;

DELETE FROM offline_user_session;
DELETE FROM [user];
DELETE FROM client;
DELETE FROM realm;

DECLARE @realm INT = 1;
WHILE @realm <= 100
BEGIN
    INSERT INTO realm (id, name, display_name, created_at)
    VALUES (
        CONCAT('realm-', FORMAT(@realm, '000000')),
        CONCAT('realm-', FORMAT(@realm, '000000')),
        CONCAT('Realm ', @realm),
        DATEDIFF_BIG(MILLISECOND, '1970-01-01', SYSUTCDATETIME())
    );
    SET @realm += 1;
END

DECLARE @client INT = 1;
WHILE @client <= 1000
BEGIN
    DECLARE @clientRealm INT = ((@client - 1) % 100) + 1;
    INSERT INTO client (id, realm_id, client_id, name, created_at)
    VALUES (
        CONCAT('client-', FORMAT(@client, '000000')),
        CONCAT('realm-', FORMAT(@clientRealm, '000000')),
        CONCAT('client-', FORMAT(@client, '000000')),
        CONCAT('Client ', @client),
        DATEDIFF_BIG(MILLISECOND, '1970-01-01', SYSUTCDATETIME())
    );
    SET @client += 1;
END

DECLARE @user INT = 1;
WHILE @user <= 10000
BEGIN
    DECLARE @userRealm INT = ((@user - 1) % 100) + 1;
    INSERT INTO [user] (id, realm_id, username, email, created_at)
    VALUES (
        CONCAT('user-', FORMAT(@user, '000000')),
        CONCAT('realm-', FORMAT(@userRealm, '000000')),
        CONCAT('user_', FORMAT(@user, '000000')),
        CONCAT('user_', FORMAT(@user, '000000'), '@example.local'),
        DATEDIFF_BIG(MILLISECOND, '1970-01-01', SYSUTCDATETIME())
    );
    SET @user += 1;
END

DECLARE @session INT = 1;
WHILE @session <= 50000
BEGIN
    DECLARE @sessionRealm INT = ((@session - 1) % 100) + 1;
    DECLARE @sessionUser INT = ((@session - 1) % 10000) + 1;
    DECLARE @sessionClient INT = ((@session - 1) % 1000) + 1;
    INSERT INTO offline_user_session (id, user_id, realm_id, client_id, offline_flag, data, last_activity_time, created_at)
    VALUES (
        CONCAT('session-', FORMAT(@session, '000000')),
        CONCAT('user-', FORMAT(@sessionUser, '000000')),
        CONCAT('realm-', FORMAT(@sessionRealm, '000000')),
        CONCAT('client-', FORMAT(@sessionClient, '000000')),
        IIF(@session % 2 = 0, 1, 0),
        N'{"state":"active"}',
        DATEDIFF_BIG(MILLISECOND, '1970-01-01', SYSUTCDATETIME()),
        DATEDIFF_BIG(MILLISECOND, '1970-01-01', SYSUTCDATETIME())
    );
    SET @session += 1;
END
