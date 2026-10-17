package io.github.prithvirajg.pictunnel.engine.net

import io.github.prithvirajg.pictunnel.engine.cred.CredentialStore
import io.github.prithvirajg.pictunnel.engine.cred.Credentials
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import java.util.concurrent.atomic.AtomicInteger

const val CLIENT = "android/0.1.0"

class FakeStore(
    var creds: Credentials?,
) : CredentialStore {
    var wipes = 0
    val saved = mutableListOf<Credentials>()

    @Synchronized override fun load(): Credentials? = creds

    @Synchronized override fun save(c: Credentials) {
        saved += c
        creds = c
    }

    @Synchronized override fun wipe() {
        wipes++
        creds = null
    }
}

fun credsFor(vararg endpoints: String) =
    Credentials(
        serverId = "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f",
        endpoints = endpoints.toList(),
        pinSpki = "",
        refreshToken = "pt_rt_0",
        deviceId = "01928f3f-1111-7000-8000-0000000d0001",
    )

fun tokens(n: Int) =
    """{"access_token":"pt_at_$n","access_token_expires_at":"2026-10-03T12:30:00Z",""" +
        """"refresh_token":"pt_rt_$n","refresh_token_expires_at":"2027-01-01T12:15:00Z"}"""

fun json(
    code: Int,
    body: String,
    contentType: String = "application/json",
) = MockResponse.Builder().code(code).addHeader("Content-Type", contentType).body(body).build()

fun problem(
    status: Int,
    code: String,
) = json(
    status,
    """{"type":"urn:pictunnel:problem:$code","title":"$code","status":$status,"detail":"d","code":"$code"}""",
    "application/problem+json",
)

/** Serves /auth/refresh with a fresh pair each time and delegates the rest to [rest]. */
class AuthingDispatcher(
    private val rest: (RecordedRequest) -> MockResponse,
) : Dispatcher() {
    val refreshes = AtomicInteger()

    override fun dispatch(request: RecordedRequest): MockResponse =
        if (request.url.encodedPath == "/api/v1/auth/refresh") {
            json(200, tokens(refreshes.incrementAndGet()))
        } else {
            rest(request)
        }
}

fun MockWebServer.base(): String = url("/").toString().trimEnd('/')

fun drain(server: MockWebServer): List<RecordedRequest> {
    val out = mutableListOf<RecordedRequest>()
    while (true) {
        out += server.takeRequest(50, java.util.concurrent.TimeUnit.MILLISECONDS) ?: return out
    }
}
