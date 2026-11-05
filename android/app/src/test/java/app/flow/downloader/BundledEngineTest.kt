package app.flow.downloader

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class BundledEngineTest {
    @Test fun readsActualArchiveVersionAndRejectsDamagedEngine() {
        val file = File.createTempFile("flow-engine", ".zip")
        try {
            ZipOutputStream(file.outputStream()).use {
                it.putNextEntry(ZipEntry("yt_dlp/version.py")); it.write("__version__ = '2025.11.12'".toByteArray()); it.closeEntry()
            }
            assertEquals("2025.11.12", BundledEngine.version(file))
            file.writeText("broken download"); assertNull(BundledEngine.version(file))
        } finally { file.delete() }
    }
    @Test fun cookieFailuresHaveAnActionableMessage() {
        val raw = "WARNING: engine old\nERROR: [Douyin] 1234: Fresh cookies (not necessarily logged in) are needed"
        val message = FailureMessage.message(raw)
        assertTrue(message.contains("抖音网页验证")); assertFalse(message.contains("engine old"))
    }
}
