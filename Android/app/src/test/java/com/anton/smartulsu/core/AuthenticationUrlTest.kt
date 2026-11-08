package com.anton.smartulsu.core

import org.junit.Assert.*
import org.junit.Test

class AuthenticationUrlTest {
    @Test fun portalContentIsNotAuthenticationIncludingUppercaseHost() {
        for (url in listOf(PortalConfiguration.GRADES, PortalConfiguration.COURSES,
            "https://PORTAL.ULSU.RU:443/my/")) {
            assertTrue(url, PortalConfiguration.allowsDataURL(url))
            assertFalse(url, PortalConfiguration.isAuthenticationURL(url))
        }
    }

    @Test fun portalLoginAndMaxChallengeRemainAuthentication() {
        for (path in listOf("/login/index.php", "/local/loginwait/wait.php", "/wait.php",
            "/realms/ulsu/login-actions/authenticate")) {
            assertTrue(path, PortalConfiguration.isAuthenticationURL(PortalConfiguration.BASE + path))
        }
    }

    @Test fun existingUniversitySsoBrowserBoundaryIsPreserved() {
        val url = "https://s1.ulsu.ru:8443/realms/ulsu/"
        assertTrue(PortalConfiguration.isAuthenticationURL(url))
        assertTrue(PortalConfiguration.allowsBrowserURL(url))
        assertFalse(PortalConfiguration.allowsDataURL(url))
    }

    @Test fun externalDomainsAndLookalikesAreNotAuthenticationEvenWithLoginPaths() {
        for (host in listOf("example.com", "portal.ulsu.ru.example.com", "evilulsu.ru",
            "ulsu.ru.example.com", "s1.ulsu.ru.example.com")) {
            for (path in listOf("/", "/login/index.php", "/local/loginwait/wait.php", "/login-actions/authenticate")) {
                val url = "https://$host$path"
                assertFalse(url, PortalConfiguration.isAuthenticationURL(url))
                assertFalse(url, PortalConfiguration.allowsBrowserURL(url))
                assertFalse(url, PortalConfiguration.allowsDataURL(url))
            }
        }
    }

    @Test fun unsafeOrMalformedUrlsAreNotAuthentication() {
        for (url in listOf("", "not a URL", "https://", "/login/index.php",
            "http://portal.ulsu.ru/login/index.php", "https://user@portal.ulsu.ru/login/index.php",
            "https://portal.ulsu.ru:123/login/index.php", "https://portal.ulsu.ru/%ZZ",
            "javascript:alert(1)", "https://portal.ulsu.ru\\@example.com/login/index.php")) {
            assertFalse(url, PortalConfiguration.isAuthenticationURL(url))
            assertFalse(url, PortalConfiguration.allowsBrowserURL(url))
        }
    }
}
