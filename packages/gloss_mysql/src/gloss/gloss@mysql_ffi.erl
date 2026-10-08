-module(gloss@mysql_ffi).
-export([coerce/1, mysql_connection/1, rsa_encrypt/2]).

coerce(Value) -> Value.

%% The driver's connection record, from pool.Connection's raw field.
mysql_connection({my_connection, _, _, _} = Connection) -> {ok, Connection};
mysql_connection(_) -> {error, nil}.

%% Encrypt Data with the server's RSA public key (PEM), OAEP padded, as
%% caching_sha2_password asks for over a connection without TLS.
rsa_encrypt(Pem, Data) ->
    try
        [Entry | _] = public_key:pem_decode(Pem),
        Key = public_key:pem_entry_decode(Entry),
        {ok, public_key:encrypt_public(Data, Key,
                                       [{rsa_padding, rsa_pkcs1_oaep_padding}])}
    catch
        _:_ -> {error, nil}
    end.
