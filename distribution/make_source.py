#!/usr/bin/env python3
"""按模板生成 SideStore 源文件，版本与体积一律取自实际构建产物。

需要的环境变量：
  APP_VERSION    CFBundleShortVersionString（从构建出的 Info.plist 读回）
  APP_BUILD      CFBundleVersion，等于 GitHub Actions 的 run_number
  BUILD_DATE     ISO 8601 时间
  IPA_SIZE       IPA 字节数
  DOWNLOAD_URL   release 资产地址，带上用于绕开缓存的查询参数
  RELEASE_NOTES  这一版的说明
  SOURCE_OUTPUT  输出路径
"""

import json
import os
import pathlib
import sys


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"缺少环境变量 {name}")
    return value


def main() -> None:
    template_path = pathlib.Path(__file__).resolve().parent / "source.template.json"
    source = json.loads(template_path.read_text(encoding="utf-8"))

    versions = source["apps"][0]["versions"]
    # nightly 只保留一条记录；AltStore 与 SideStore 都把数组第一项当作最新版本。
    versions[:] = [
        {
            "version": required("APP_VERSION"),
            "buildVersion": required("APP_BUILD"),
            "date": required("BUILD_DATE"),
            "localizedDescription": required("RELEASE_NOTES"),
            "downloadURL": required("DOWNLOAD_URL"),
            "size": int(required("IPA_SIZE")),
            "minOSVersion": versions[0].get("minOSVersion", "16.0"),
        }
    ]

    output = pathlib.Path(required("SOURCE_OUTPUT"))
    output.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"已生成 {output}：{versions[0]['version']} ({versions[0]['buildVersion']})")


if __name__ == "__main__":
    main()
