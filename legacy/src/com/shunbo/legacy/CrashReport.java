package com.shunbo.legacy;

import android.content.Context;

import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * 无 adb 环境下的崩溃留痕与自显。
 *
 * <p>这台乐视电视没有 adb 连接，闪退时拿不到 logcat。这里做两件事：
 * ① 进程默认未捕获异常处理器把堆栈同步写进 app 私有目录的 last_crash.txt；
 * ② 下一次启动时在「菜单键」信息页里显示这份记录，用户拍一张照片即可
 *    把真实异常类名和栈顶回传，不必再靠静态推断。
 *
 * <p>只用 API 1 起就存在的接口（Context.openFileOutput / openFileInput），
 * 不引第三方库、不申请权限、不访问外部存储。
 */
public final class CrashReport {

    private static final String FILE = "last_crash.txt";
    private static final int MAX_STORE = 8000;
    private static final int MAX_SHOW = 900;

    private CrashReport() {}

    /** 在 Activity.onCreate 的第一行调用；系统默认处理器继续负责终止进程。 */
    public static void install(final Context context) {
        final Context app = context.getApplicationContext();
        final Thread.UncaughtExceptionHandler previous =
                Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler(
                new Thread.UncaughtExceptionHandler() {
                    @Override
                    public void uncaughtException(Thread thread, Throwable error) {
                        try {
                            write(app, "uncaught", error);
                        } catch (Throwable ignored) {
                            // 留痕失败绝不能覆盖原始异常。
                        }
                        if (previous != null) previous.uncaughtException(thread, error);
                    }
                });
    }

    /** 启动流程内被 try/catch 兜住的异常，也要留痕（不会导致进程退出）。 */
    public static void record(Context context, String stage, Throwable error) {
        try {
            write(context.getApplicationContext(), stage, error);
        } catch (Throwable ignored) {
        }
    }

    /** 读回上一次崩溃；没有记录返回 null。 */
    public static String readLast(Context context) {
        try {
            byte[] buf = readAll(context);
            return buf == null ? null : new String(buf, "UTF-8");
        } catch (Throwable ignored) {
            return null;
        }
    }

    public static void clear(Context context) {
        try {
            context.deleteFile(FILE);
        } catch (Throwable ignored) {
        }
    }

    /** 屏显用的短摘要：异常类 + 消息 + 前若干行堆栈。 */
    public static String shortTrace(Throwable error) {
        if (error == null) return "（无异常对象）";
        String full = stackTrace(error);
        return full.length() > MAX_SHOW ? full.substring(0, MAX_SHOW) + "\n…（已截断）" : full;
    }

    public static String stackTrace(Throwable error) {
        StringWriter sw = new StringWriter();
        PrintWriter pw = new PrintWriter(sw);
        try {
            error.printStackTrace(pw);
        } finally {
            pw.flush();
        }
        return error.getClass().getName() + ": " +
                (error.getMessage() == null ? "" : error.getMessage()) + "\n" + sw.toString();
    }

    private static void write(Context context, String stage, Throwable error) {
        String stamp = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
                .format(new Date());
        String body = "stage=" + stage + " time=" + stamp + "\n" + stackTrace(error);
        if (body.length() > MAX_STORE) body = body.substring(0, MAX_STORE);
        FileOutputStream out = null;
        try {
            out = context.openFileOutput(FILE, Context.MODE_PRIVATE);
            out.write(body.getBytes("UTF-8"));
            out.flush();
        } catch (IOException ignored) {
        } catch (Throwable ignored) {
        } finally {
            if (out != null) {
                try { out.close(); } catch (IOException ignored) {}
            }
        }
    }

    private static byte[] readAll(Context context) throws IOException {
        java.io.FileInputStream in = null;
        try {
            in = context.openFileInput(FILE);
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        } finally {
            if (in != null) {
                try { in.close(); } catch (IOException ignored) {}
            }
        }
    }
}
