FROM fnproject/python:3.11-dev@sha256:963c337d7511446a1b5f6fa862f303c47b7e4f00f57d1fd7426fdaa971307067 AS build-stage
WORKDIR /function
ADD requirements.txt /function/
RUN pip3 install --target /python/ --no-cache-dir -r requirements.txt
ADD . /function/
RUN rm -fr /function/.pytest_cache

FROM fnproject/python:3.11@sha256:7bd33de8507d0b647fcaac64e8e149bee35ecc37a58c408d25ff448007b7ea42
WORKDIR /function
COPY --from=build-stage /python /python
COPY --from=build-stage /function /function
ENV PYTHONPATH=/function:/python
ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
