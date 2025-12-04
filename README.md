# Hellgate

Core logic service for payment states processing.

## Building

To build the project, run the following command:

```bash
$ make compile
```

## Running

To enter the [Erlang shell][1] with the project running, run the following command:

```bash
$ make rebar-shell
```

## Development environment

### Run in a docker container

You can run any of the tasks defined in the Makefile from inside of a docker container (defined in `Dockerfile.dev`) by prefixing the task name with `wc-`. To successfully build the dev container you need `Docker BuildKit` enabled. This can be accomplished by either installing [docker-buildx](https://docs.docker.com/buildx/working-with-buildx/) locally, or exporting the `DOCKER_BUILDKIT=1` environment variable.

#### Example

* This command will run the `compile` task in a docker container:
```bash
$ make wc-compile
```

### Run in a docker-compose environment

Similarly, you can run any of the tasks defined in the Makefile from inside of a docker-compose environment (defined in `docker-compose.yaml`) by prefixing the task name with `wdeps-`. To successfully build the dev container you need `Docker BuildKit` enabled (see `Run in a docker container` section). It *may* also be necessary to export a `COMPOSE_DOCKER_CLI_BUILD=1` environment variable for `docker-compose` container builds to work properly.

#### Example

* This command will run the `test` task in a docker-compose environment:
```bash
$ make wdeps-test
```

## Documentation

@TODO Please write a couple of words about what your project does and how it does it.

[1]: http://erlang.org/doc/man/shell.html

# Fistful

> Wallet Processing Service

## Development plan

### Бизнес-функционал

* [x] Минимальный тестсьют для кошельков
* [x] Реализовать честный identity challenge
* [x] Запилить payment provider interface
* [ ] Запилить контактные данные личности
* [x] Запилить нормально трансферы
* [ ] Заворачивать изменения в единственный ивент в рамках операции
* [.] Компактизировать состояние сессий
* [ ] Запилить контроль лимитов по кошелькам
* [ ] Запилить авторизацию по активной идентификации
* [ ] Запилить отмену identity challenge
* [ ] Запускать выводы через оплату инвойса провайдеру выводов
* [ ] Обслуживать выводы по факту оплаты инвойса

### Корректность

* [.] Схема хранения моделей
* [ ] [Дегидратация](#дегидратация)
* [ ] [Поддержка checkout](#поддержка-checkout)
* [ ] [Коммуналка](#коммуналка)

### Удобство поддержки

* [ ] Добавить [служебные лимиты](#служебные-лимиты) в рамках одного party
* [ ] Добавить ручную прополку для всех асинхронных процессов
* [ ] Вынести _ff_withdraw_ в отдельный сервис
* [ ] Разделить _development_, _release_ и _test_ зависимости
* [ ] Вынести части _ff_core_ в _genlib_

## Поддержка checkout

Каждая машина, на которую мы можем сослаться в рамках асинхронной операции, должно в идеале давать возможность _зафиксировать версию_ своего состояния посредством некой _ревизии_. Получение состояния по _ревизии_ осуществляется с помощью вызова операции _checkout_. В тривиальном случае _ревизия_ может быть выражена _меткой времени_, в идеале – _номером ревизии_.

## Коммуналка

Сервис должен давать возможность работать _нескольким_ клиентам, которые возможно не знают ничего друг о друге кроме того, что у них разные _tenant id_. В идеале _tenant_ должен иметь возможность давать знать о себе _динамически_, в рантайме, однако это довольно трудоёмкая задача. Если приводить аналогию с _Riak KV_, клиенты к нему могут: создать новый _bucket type_ с необходимыми характеристиками, создать новый _bucket_ с требуемыми параметрами N/R/W и так далее.

## Дегидратация

В итоге как будто бы не самая здравая идея. Есть ощущение, что проще и дешевле хранить и оперировать идентификаторами, и разыменовывать их каждый раз по необходимости.

## Служебные лимиты

Нужно уметь _ограничивать_ максимальное _ожидаемое_ количество тех или иных объектов, превышение которого может негативно влиять на качество обслуживания системы. Например, мы можем считать количество _выводов_ одним участником неограниченным, однако при этом неограниченное количество созданных _личностей_ мы совершенно не ожидаем. В этом случае возможно будет разумно ограничить их количество сверху труднодостижимой для подавляющего большинства планкой, например, в 1000 объектов. В идеале подобное должно быть точечно конфигурируемым.
