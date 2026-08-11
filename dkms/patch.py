#!/usr/bin/env python3
"""
e3372-driver — патч драйвера rndis_host.

Проблема
--------
generic_rndis_bind() сообщает устройству максимальный размер транзфера,
беря его из rx_urb_size:

    dev->rx_urb_size = dev->hard_mtu + (dev->maxpacket + 1);
    dev->rx_urb_size &= ~(dev->maxpacket - 1);
    u.init->max_transfer_size = cpu_to_le32(dev->rx_urb_size);

Для High-Speed это даёт (1558 + 513) & ~511 = 2048 байт. Модем честно
уважает это число и режет батчи так, что RNDIS-сообщения не помещаются
в один URB. А rndis_rx_fixup() собирать сообщение через границу URB не
умеет: каждый буфер разбирается отдельно, поэтому у сообщения, начавшегося
в предыдущем URB, «заголовком» оказывается кусок полезных данных.

Итог: ~85% принятых пакетов уходит в rx_length_errors + rx_frame_errors,
download падает до ~1.3 Мбит при совершенно здоровом upload.

В логе это выглядит так (dynamic_debug на модуле):
    bad rndis message 1/1460/36/1414, len 588
то есть заголовок корректен (36+1414+8 <= 1460), но пришло 588 из 1460.

Замерено на живом парке K5160:
    было   download 1.26 Мбит/с,  upload  8.69,  ошибок приёма ~85%
    стало  download 46.58 Мбит/с, upload 43.66,  ошибок приёма ~0%

Баг не специфичен для Huawei: та же сигнатура известна на Samsung
(linux-usb, Debian #889831, открыт с 2018 и не исправлен).

Решение
-------
Дать возможность переопределить rx_urb_size параметром модуля. Значение
уходит в max_transfer_size, модем начинает укладывать батчи в наш буфер,
и парсер перестаёт видеть обрывки.

Запуск:  python3 patch.py <путь к rndis_host.c>
Идемпотентен: повторный прогон ничего не делает.
"""

import re
import sys
import pathlib

PARAM_BLOCK = """

/* --- e3372-driver: обход разрыва RNDIS-сообщений между URB ---------------- *
 * Штатный расчёт даёт rx_urb_size = 2048, устройство режет батчи под это
 * число, и сообщения перестают помещаться в один URB. Позволяем задать
 * размер вручную; 0 сохраняет поведение ядра без изменений.
 * -------------------------------------------------------------------------- */
static unsigned int rx_urb_size_override;
module_param(rx_urb_size_override, uint, 0644);
MODULE_PARM_DESC(rx_urb_size_override,
\t"e3372: override RX URB size / negotiated RNDIS max_transfer_size (0 = kernel default)");
"""

ANCHOR = r'^([ \t]*)u\.init->max_transfer_size = cpu_to_le32\(dev->rx_urb_size\);'


def main() -> int:
    if len(sys.argv) != 2:
        print("использование: patch.py <rndis_host.c>", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        print(f"нет файла: {path}", file=sys.stderr)
        return 1

    src = path.read_text()

    if "rx_urb_size_override" in src:
        print("  уже пропатчен")
        return 0

    includes = list(re.finditer(r"^#include .*$", src, re.M))
    if not includes:
        print("  НЕ НАЙДЕНО ни одного #include — файл не похож на rndis_host.c",
              file=sys.stderr)
        return 1
    pos = includes[-1].end()
    src = src[:pos] + PARAM_BLOCK + src[pos:]

    m = re.search(ANCHOR, src, re.M)
    if not m:
        print("  НЕ НАЙДЕНА строка max_transfer_size = cpu_to_le32(dev->rx_urb_size)",
              file=sys.stderr)
        print("  Возможно, апстрим переписал generic_rndis_bind(). "
              "Патч нужно переносить вручную.", file=sys.stderr)
        return 1

    indent = m.group(1)
    injection = (f"{indent}if (rx_urb_size_override)\n"
                 f"{indent}\tdev->rx_urb_size = rx_urb_size_override;\n")
    src = src[:m.start()] + injection + src[m.start():]

    path.write_text(src)
    print("  пропатчен")
    return 0


if __name__ == "__main__":
    sys.exit(main())
