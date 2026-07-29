import os
import random
import time

from locust import HttpUser, between, task


SESSION_COUNT = int(os.getenv("SESSION_COUNT", "50000"))
USER_COUNT = int(os.getenv("USER_COUNT", "10000"))
SESSION_PREFIX = os.getenv("SESSION_PREFIX", "session-")
USER_PREFIX = os.getenv("USER_PREFIX", "user-")


def random_session_id():
    return f"{SESSION_PREFIX}{random.randint(1, SESSION_COUNT):06d}"


def random_user_id():
    return f"{USER_PREFIX}{random.randint(1, USER_COUNT):06d}"


class KeycloakSimulator(HttpUser):
    wait_time = between(0.01, 0.03)

    @task(80)
    def get_session(self):
        self.client.get(f"/test/session/{random_session_id()}", name="GET /test/session/{id}")

    @task(15)
    def update_session(self):
        self.client.put(
            f"/test/session/{random_session_id()}",
            json={"last_activity": int(time.time() * 1000)},
            name="PUT /test/session/{id}",
        )

    @task(5)
    def get_user(self):
        self.client.get(f"/test/user/{random_user_id()}", name="GET /test/user/{id}")
