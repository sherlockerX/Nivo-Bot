package io.github.nanomuse.routines;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** 独立Java子进程替身，只输出合成文本，不执行命令或访问网络。 */
public final class ScheduledProcessFixture {
    /** 供进程捕获测试选择固定输出、字面参数或慢退出。 */
    public static void main(String[] arguments) throws Exception {
        switch (arguments[0]) {
            case "args":
                for (int index = 1; index < arguments.length; index++) {
                    System.out.println(Base64.getEncoder().encodeToString(arguments[index].getBytes(StandardCharsets.UTF_8)));
                }
                break;
            case "mixed":
                System.out.print("FIRST");
                System.err.print("STDERR_ONLY");
                Thread.sleep(30);
                System.out.print("LAST");
                break;
            case "payload":
                System.out.print("x".repeat(719));
                break;
            case "large":
                System.out.print("x".repeat(200000));
                break;
            case "failure":
                System.out.print("BEFORE_FAILURE");
                System.exit(7);
                break;
            case "slow":
                Thread.sleep(30000);
                break;
            case "stdin":
                System.out.print(System.in.read() == -1 ? "EOF" : "UNEXPECTED_INPUT");
                break;
            default:
                break;
        }
    }
}
