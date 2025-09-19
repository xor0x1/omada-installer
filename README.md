# Omada Installer (safe fork)

> Безопасный установщик TP-Link Omada Software Controller для Ubuntu  
> _Fork оригинального [omada-installer](https://github.com/monsn0/omada-installer) от [@monsn0](https://github.com/monsn0)._

---

## О проекте

Оригинальный [скрипт](https://github.com/monsn0/omada-installer) 

Наш форк сохранил простоту исходного решения, но добавил:

- Поддержку **Ubuntu 24.10 (oracular)** с фоллбэком репозитория MongoDB на noble.
- Безопасные дефолты: `set -Eeuo pipefail`, остановка при ошибках.
- Автоматическую установку зависимостей (`curl`, `gpg`, `jq`, `tar` и др.).
- Парсинг последних стабильных версий Omada на сайтах TP-Link / OmadaNetworks  
  (понимает `.deb` и `.tar.gz` пакеты, ссылки на `static.tp-link.com`).
- Проверку домена скачиваемого файла и (опционально) SHA256-хеша.
- Возможность сразу ограничить доступ к веб-интерфейсу (порт `8043`) через UFW.
- Поддержку как `.deb`, так и архивов `.tar.gz` (автоматический запуск `install.sh`).
- Корректное завершение установки и автозапуск сервиса.

> Все оригинальные права на скрипт принадлежат [@monsn0](https://github.com/monsn0).  
> Наши изменения распространяются на тех же условиях, что и лицензия исходного проекта.

---

## Поддерживаемые системы

| Ubuntu release | Codename | Статус |
|----------------|----------|--------|
| 20.04 LTS      | focal    | ✅ |
| 22.04 LTS      | jammy    | ✅ |
| 24.04 LTS      | noble    | ✅ |
| 24.10          | oracular | ⚠️ — MongoDB берётся из noble repo |

---

## Установка

### 1️⃣ Скачайте и дайте права на запуск

```bash
curl -sS https://raw.githubusercontent.com/xor0x1/omada-installer/refs/heads/main/install-omada-controller.sh | sudo bash


## Usage
To manage the controller service, use the `tpeap` script as root.
The script is located as a symlink in `/usr/bin`

```
usage: tpeap help
       tpeap (start|stop|status|version)

help       - this screen
start      - start the service(s)
stop       - stop  the service(s)
status     - show the status of the service(s)
version    - show the version of the service(s)
```

## Links
Offical guide: https://www.tp-link.com/us/support/faq/3272/

Guide by @willquill : https://www.reddit.com/r/HomeNetworking/comments/mv1v9d/guide_how_to_set_up_omada_controller_in_ubuntu/ / https://github.com/willquill/omada-ubuntu

Upgrade guide: https://www.tp-link.com/en/omada-sdn/controller-upgrade/
