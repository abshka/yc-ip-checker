# Инструкция по применению
1. Подключиться к VPS, желательно в самом YC (для простоты), но можно и на другой Linux машине
2. Установить yc: curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
3. Установить jq: sudo apt install jq
4. Авторизоваться в yc: yc init
5. Зайти под рутом: sudo -i
6. Скачать скрипт: wget https://github.com/abshka/yc-ip-checker/ip-checker.sh
7. Сделать его исполняемым: chmod +x ip-checker.sh
8. Получить folder-id: yc config list и в графе folder-id скопировать значение
9. Открыть скрипт и заменить folder-id: nano ip-checker.sh и вместо your-folder-id поставить скопированный folder-id
10. Запустить собственно скрипт: ./ip-checker.sh

