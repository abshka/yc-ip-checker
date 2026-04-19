# Инструкция по применению
1. Подключиться к VPS, желательно в самом YC (для простоты), но можно и на другой Linux машине
2. Установить yc: curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
3. Установить jq: sudo apt install jq
4. Авторизоваться в yc: yc init
5. Зайти под рутом: sudo -i
6. Скачать скрипт: wget https://raw.githubusercontent.com/abshka/yc-ip-checker/refs/heads/main/ip-checker.sh
7. Сделать его исполняемым: chmod +x ip-checker.sh
8. Запустить собственно скрипт: ./ip-checker.sh

