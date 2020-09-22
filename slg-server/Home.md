# 1 简介
---
这是一篇描述erlang游戏服务器设计的文章。

一年前我学习erlang的时候，网上可以获取到的书籍非常少，学习的时候走了不少弯路，而如今我已经对erlang游戏服务器编程比较熟悉了，所以我想把这些设计经验和erlang相关的知识写下来，一方面减少新手学习erlang的痛苦，另一方面为自己备个案，然后就是给大家review，以便不断改进它。

本文是结合我自己的项目[slg-server](https://github.com/zhuoyikang/slg-server)来描述的，当然我非常欢迎您阅读我的代码或者提出修改意见。

slg-server不使用分布式erlang，按照现在游戏界比较流行的做法：一个逻辑服务器负载大概几W人，同时在线人数几千人，如果人数多了，通过不断的开新服来缓解压力，所以本文是针对这种小服的游戏服务器来讨论。

## 1.1 综述
---

一个游戏服务器的设计需要包含哪些模块，我觉得大概有以下四个部分：

* *连接处理(slg-proto)*: 客户端通过tcp和服务器建立连接通信，因此需要一个连接处理；既然要通信，当然必须要定义通信协议，这是第二部分，然后就是传输内容的加密，这三部分完成，连接处理基本就搞定了。
* *数据处理(slg-model)*：一个玩家的数据是游戏中最重要的部分，一般采用MySql存储，另一方面MySql的操作速度太慢，需要将玩家数据加载到内容中，使得绝大多数操作都在内存中直接进行，然后再异步的回写到MySql持久化。
* *配置处理(slg-csv)*：每个游戏服务器中都有大量的gd配置文件，一般都是Excel格式，当然erlang不能直接处理，所以第一步要先把excel导出为csv格式，我使用python处理；另一部分把csv直接映射到ets表，然后编程的时候就可以直接通过访问ets来访问gd配置的内容了。
* *其他(slg-support)*：不管是游戏服务器还是erlang本身都有些好用的工具和可复用的编程模块，我把它们收集起来方便使用。

其中每一个都对应一个单独的项目，在源码中的[config/rebar.config](https://github.com/zhuoyikang/slg-server/blob/master/config/rebar.config)依赖指定。


## 1.2 前提
---

如果你想继续往下看，请确保你对erlang有了以下了解：

* 基本掌握erlang的顺序式
* 基本掌握erlang并发编程
* 掌握OTP(gen_server,gen_supervisor等)。

有了这些基础，你可以无障碍的阅读源码。


# 2 连接处理 slg-proto
---
连接处理指的是处理客户端和服务器的连接通信。

由于erlang的轻量级进程让连接处理编写起来非常简单，首先有个监听进程，它监听某个端口，不断的处理客户端新发起的连接，每一个客户端的连接都会被监听者返回一个新的socket，这时候新开一个进程来处理这个socket，它可以接受socekt数据，或者通过它向客户端发送数据。

## 2.1 监听进程
---
监听进程我在代码中将其命名为[conn_acceptor](https://github.com/zhuoyikang/slg-proto/blob/master/src/conn_acceptor.erl)，代表连接接受者，下面两句代码将创建一个监听套接字：

```
%% 执行监听.
listen_port() ->
  Options = [binary, {packet, 0}, {reuseaddr, true},
             {backlog, 1024}, {active, false}],
  gen_tcp:listen(4000, Options).
```
而整个`conn_acceptor`进程处在这个循环函数里：

```
%% 监听循环.
acceptor_loop(ListenSocket) ->
  case (catch gen_tcp:accept(ListenSocket, 50000)) of
    {ok, Socket} -> handle_connection(Socket);
    {error, Reason} -> handle_error(Reason);
    {'EXIT', Reason} -> handle_error({exit, Reason})
  end,
  acceptor_loop(ListenSocket).
```
这样[conn_acceptor](https://github.com/zhuoyikang/slg-proto/blob/master/src/conn_acceptor.erl)接受完一个连接后，又继续等待下一个连接的到来，而gen_tcp:acceptor的第二个参数表示等待超时时间。

这里是关[accept](http://erlang.org/doc/man/gen_tcp.html#accept-2)函数的描述。

再连接到来之后，使用`handle_connection处理`，代码如下：

```
%% 新的客户端连接建立.
do_handle_connection(Socket) ->
  case conn_super:start_player(Socket) of
    {ok, PlayerPID} -> gen_tcp:controlling_process(Socket, PlayerPID);
    {error, Reason}->  io:format("error ~p~n", [Reason])
  end.
```
在代码中conn_super为所有连接进程的监督者，虽然连接进程不需要做重启之类的工作，但是为了框架的一致，连接处理进程都在conn_super的监督之下。

需要注意的是以下代码：
```
gen_tcp:controlling_process(Socket, PlayerPID);
```
这行代码将该Socket的处理进程设置为刚刚建立起来的连接处理进程，这样从socket传来的数据可以直接在该进程的handle_info函数中处理，非常方便。

## 2.2 连接处理进程
---

这部分的代码位于[conn.erl](https://github.com/zhuoyikang/slg-proto/blob/master/src/conn.erl)，它是一个gen_server，值得注意的其init函数

```
init([Socket]) ->
  process_flag(trap_exit, true),
  inet:setopts(Socket, [{active, once}, {packet, 2}, binary]),
  State = #state{socket = Socket},
  erlang:put(socket, Socket),
  {ok, State}.
```

其中`inet:setopts(Socket, [{active, once}, {packet, 2}, binary]),`设置了两个选项：

### 2.2.1 {active, once}
---

 *{active, once}*：一般情况下，socket的数据接收是用`gen_tcp:recv`函数，但是可以通过这个参数设置以后，socket的数据可以通过消息来处理，也就是说有socket数据来的时候，该进程会收到一个`handle_info({tcp, Socket, Bin}, State)`消息，这样处理起来非常方便。但是once的指明这样的行为只发生一次，下一次你还是要通过`gen_tcp:recv`函数获取数据，所以为了方便，`hanle_info`里重复设置了这个选项：
 
 ```
 handle_info({tcp, Socket, Bin}, State) ->
  inet:setopts(Socket, [{active, once}, {packet, 2}, binary]),
  ...
 ```
 你可以设置为{active, false}，这样将只能使用gen_tcp:recv接受消息，或者{active,true}表示每次都通过handle_info接受消息。
 
 而{active, once}的意义在于可以避免设置为{active, true}时大量的socket的消息发生给进程，造成进程处理不了其他消息。
 
### 2.2.2 {packet, 2}
---
这个选项设置对于每个通过gen_tcp:send发出的数据包，erlang都自动在前面加上两个字节，而这两个字节表示的是你要发送数据包的长度。

同时，当erlang在底层为socket监听数据时{active, once}，也假设每个包的前两个字节是整个包的长度，如果包未接受完整，erlang会自动帮你处理缓存，直到包数据完全接受再发送({tcp, Socket, Bin},消息，非常强大。

所以如果你是C/C++程序员，套接字缓存通过这个参数的设置就完全搞定了，我想这也是游戏行业不少人选择erlang的原因之一。

### 2.2.3 hotwheels
---
整个连接处理部分包括conn_acceptor和conn.erl，而代码本省其实不是我写的，是我学习erlang的时候从[hotwheels](https://github.com/tolbrino/hotwheels)里面移植过来的，hotwheels是erlang tcp连接处理的典范。

好了，这就是整个客户端和服务器通信的传输层，你可以自己写个echo-server来试试，达到完全掌握的程度。

C/C++程序员可能会疑惑为什么没有epoll等io多路复用处理，其实呢erlang虚拟机已经帮你处理了，你只需要随便开一个进程来处理一个连接，因为在erlang中，进程本身和进程切换都非常廉价。

## 2.3 数据序列化和协议设计
---

### 2.3.1 文本协议 VS 二进制协议
---
在游戏服务器设计之初，我曾经纠结过是否使用文本协议，而对于游戏服务器来说，使用文本协议比如Json或者Xml有以下坏处：

1. 占用更大的流量：如果你是手游，使用Json或者Xml协议带来的流量将会是二进制协议的好几倍,而每个手机用户的流量都是有限的，如果能省下来将会是一个游戏相比竞争对手的优势。
2. erlang处理字符串很糟糕：这个学过erlang的应该都知道，erlang的字符串是链表，一个链表节点至少耗8个字节，更耗内存，然而erlang处理二进制非常优秀，所以二进制是更适合erlang的选择。

### 2.3.2 二进制协议
---
如何设计协议，这是一个问题，可以思考一下：首先要有包类型，这个非常容易理解，比如登陆请求包，建筑升级包，充值请求包等不同的包用来完成不同的逻辑功能，而区分不同的包类型只要一个数字就行了，只要客户端和服务器约定好不同数字对应的包类型是什么。

其次要设计包内容，因为登陆请求包发送的是用户名和密码，建筑升级包发送的建筑相关信息，不同的包的内容是不一样的，是需要根据游戏逻辑来设计的，所以协议设计集中在*包类型*和*包内容*处理。

加上之前的两个字节的{packet, 2}，一个完整的包应该是下图所示的二进制序列：

	--------------------------------------
	|包头(2字节)|包类型(2字节)|包内容(剩余字节)|
	--------------------------------------

每一个tcp连接都应该先收取2个字节，获得其后包类型和和包内容的完整数据。然后取完整数据的前2个字节为包类型，这个包类型决定了包内容的所描述的数据结构。所以包头和包类型都很简单编程，复杂的是包内容。

### 2.3.2 整型序列化
---
包内容就是用了二进制序列化逻辑数据结构，比如google protobuff就是干这样的事情，不过我不打算用，因为它太强大太复杂，绝大多数的功能用不上，而且对erlang也不是官方支持。

先不要想的太复杂，你可以考虑以下如果使用二进制表示一个最简单的数据类型，比如如何表示一个boolean值，非常简单，0表示false， 1表示true，所以只需要一个字节即可，那么包含了一个boolean类型数据的完整的包就是这样：
```
--------------------------------------
|包头(2字节)|包类型(2字节)|1字节(0或1)|
--------------------------------------
```
现在设类型1的包内容就是一个简单的boolean类型，那么当读出包类型为1的时候，最后肯定只剩下1个字节，我们把它转成char即可，很简单。

可以看出，因为我们知道boolean类型的长度，可以直接在包内容中取1个字节即可。

那么也可以设计一个int32类型的数据类型，它就是占用4个字节而已，我们可以通过以下erlang代码直接将一个数字转换为一个32位的二进制表示(补码表示)：

```
encode_integer(Int) when is_integer(Int) ->
  <<Int:32>>.
```
也可以使用如下代码将二进制转换为int数字:

```
decode_integer(<<Integer:32/signed, Data/binary>>)  ->
  {Integer, Data}.
```

使用erlang干这个事情太简单了！！！，可以一口气把常用整形的序列化的全部写出来：

```
encode_integer(Int) -> <<Int:32>>.
decode_integer(<<Integer:32/signed-big-integer, Data/binary>>)  ->
  {Integer, Data}.
  
%% 解析short
encode_short(Short) -> <<Short:16/signed-big-integer>>.
decode_short(<<Short:16/signed-big-integer, Data/binary>>)  ->
  {Short, Data}.
...
```

这部分代码我在[slg_proto](https://github.com/zhuoyikang/slg-proto/blob/master/src/proto_payload.erl)里面实现了。

### 2.3.3 字符串序列化
---
整形是定长类型，所以比较好处理，那么字符串这样的变长类型怎么处理，事先是不可能知道一个字符串的长度的，所以序列化过程需要包含其长度，对于字符串类型的序列化，设计前两个字节为整个字符串类型的长度，然后字符串内容紧跟其后：

```
-----------------------------------
|字符串长度(2字节)|字符串内容(剩余字节)|
-----------------------------------
```
所以可以写出字符串类型的序列化函数：

```
%% 解析string
encode_string(String) when is_list(String) ->
  StringLen = length(String),
  %% BinS = unicode:characters_to_binary(String),
  %%L = byte_size(BinS),
  list_to_binary([<<StringLen:16>>, String]).  
decode_string(<<Length:16/unsigned-big-integer,Data/binary>>)  ->
  {StringData, StringLeftData} = split_binary(Data,Length),
  String = StringData, %%, binary_to_list(StringData),
  {String, StringLeftData}.
```
注意，这里的字符串序列化其实对erlang而言是binary类型的序列化，因为在erlang代码中我们将对字符串使用binary类型而非list，使用<<"name">>而非"name"。

### 2.3.4 类型嵌套
---
那么，如果序列化一个玩家的登陆信息，包括(账号，密码和性别)三个字段，从包内容来看，分别是 字符串类型|字符串类型|char类型：

```
----------------------------------------------------------------
|账号字符串长度(2字节)|账号字符串内容|密码长度(2字节)|密码内容|性别(1字节)|
----------------------------------------------------------------
```

所以如果要对这个登陆数据进行序列化，代码应该如下：

```
假设登陆类型为record(login, {name,password,sex}
encode_login(Login) ->
	NameBin = encode_string(Login#login.name),
	PasswordBin = encode_string(Login#login.password),
	SexBin = encode_string(Login#login.sex),
	list_to_binary([NameBin, PasswordBin, SexBin]).
decode_login(<<Data/binary>>) ->
	{Name, NameLeft} = decode_string(Data),
	{Password, PassLeft} = decode_string(NameLeft),
	{Sex, SexLeft} = decode_char(PassLeft),
	Login = #login{name=Name, password=Password, sex=Sex},
	{Login, SexLeft}
```

`decode_`函数同时也返回了剩余的包内容给后续处理，我们实现了一个自定义的login类型处理，它使用起来和基础类型一样，但它是由基础类型组合而成的。

同样，我们也可以用这个组合类型login来组合成更复杂的类型，这就是`类型嵌套`。

有了基础数字和字符串类型+类型嵌套，已经可以组合出非常复杂的类型了，但是还有一个必须的处理，那就是`数组`。

### 2.3.5 数组序列化
---

数组的表示是游戏里不可缺少的，一个玩家可能有多个建筑，需要用数组表示；有多个好友，也用数组表示，等等，那如何序列化一个数组呢？

```
---------------------------
|数组元素个数(2字节)| 数组内容|
--------------------------
```

你可以这样想，知道了数组的元素的个数n和数组的类型，就可以调用*encode_类型*或者*decode_类型*n次来完成数组类型的序列化，所以我使用以下代码来序列化数组：

```
%% 解析数组编码
encode_array_item([],_Fun) ->
  [];
encode_array_item([H|T],Fun) ->
  [proto_payload:Fun(H) | encode_array_item(T,Fun)].
encode_array(Array,Fun) when is_list(Array) ->
  List = encode_array_item(Array,Fun),
  ListData = list_to_binary(List),
  ListLen = length(List),
  list_to_binary([<<ListLen:16/unsigned-big-integer>>, ListData]).
decode_array_item(0, <<Data/binary>>, _Fun) ->
  [Data];
decode_array_item(N, <<Data/binary>>, Fun) ->
  {Item, ItemDataLeft} = proto_payload:Fun(Data),
  [Item | decode_array_item(N-1, ItemDataLeft, Fun)].
decode_array(<<ArrayLen:16/unsigned-big-integer, Data/binary>>, Fun) ->
  ArrayItem = decode_array_item(ArrayLen, Data, Fun),
  Length = length(ArrayItem),
  {Array, [ArrayDataLeft]} = lists:split(Length-1, ArrayItem),
  {Array, ArrayDataLeft}.
```
数组元素的序列化将成为第3个参数Fun，这样就可以用这段代码来处理不同的数组类型了。

所以序列化一个含有3个integer类型的数组调用如下：

```
encode_array([2,3], encode_integer) -> …
decode_array(Binary, encode_integer) -> … 
```

### 2.3.6 协议设计
---

总结一下上文，客户端和服务器都通过包类型来决定如何序列化数据和包内容；客户端和服务器都知道包内容是由什么数据组成的，以及它们的类型。然而口头上的约定不足以保证程序的正确和健壮，这个时候需要一个中间文件来对包类型和包内容进行统一的描述。

#### 2.3.6.1 包类型api.txt

在slg_proto的[proto/api.txt](https://github.com/zhuoyikang/slg-proto/blob/master/proto/api.txt)里面列出了游戏服务器中的所有的包类型：

```
packet_type:10001
name:code_ack
payload:pt_code
desc:待用加密key.

packet_type:1
name:login_req
payload:pt_account
desc:待用加密key.
module:conn_test
```

它们每一个都包含以下属性：

* packet_type: 包类型ID，是个唯一的数字，10000号以上用作功能，10000以下用作逻辑使用。
* name:包名字，程序中我希望直接使用名字来操作包，而不是数字，这样更友好。
* payload:包内容的类型，将在下面描述。
* desc:一段间断的注释，描述它的作用。
* module:直接指明包的处理模块，它将会去该模块寻找其与name同名的函数调用处理该包。

#### 2.3.6.2 包内容api.txt

在slg_proto的[proto/protocal.txt](https://github.com/zhuoyikang/slg-proto/blob/master/proto/protocal.txt)里面列出所有的包内容类型：

    # 普通错误回复
	pt_code=
	api integer
	code integer
	===

	# 玩家基本信息
	# name 名字
	# sex 性别
	pt_ubase=
	name string
	sex string
	===
	
	# 玩家建筑信息
	db_building=
	id pkid
	user_id pkid
	b_type string
	sort integer
	level integer
	===
	
	# 建筑类型列表
	db_buildings=
	buildings db_building $array
	===
	
客户端和服务器将通过这两个文件约定协议，并各自编写程序生成其序列化和反序列化代码。

有以下基础类型：

integer, uinteger, short, ushort, char, uchar, boolean, string, pkid。

pkid是专门为主键设计的数据类型，它其实是被序列化为string类型。

#### 2.3.6.2 代码生成

知道了内容类型后序列化和反序列化代码就变成了单独无聊的工作，所以我写了个ruby程序来通过协议文件生成这部分代码：[proto_gen2.rb](https://github.com/zhuoyikang/slg-proto/blob/master/src/proto_gen2.rb)。

有了代码生成器，每次修改了协议内容，只需要在项目目录下执行make g即可重新生成代码，生成的代码路径为：proto/code/

* proto_api.erl: API名字和ID的映射函数。
* proto_decoder.erl: API的解包函数。
* proto_encoder.erl: API的打包函数。
* proto_error.erl:错误码映射函数。
* proto_indian.hrl: 包内容打包和解包函数。
* proto_record.hrl: 将protocal.txt的数据结构转为record。
* proto_route.erl: 每一个名字req结尾的包类型都会在其中找到其处理函数。

这就是协议生成的详细内容，如果你完全理解了这部分，协议处理就搞定了。

### 2.3.7 加密解密
---

每个公司或者项目有自己对加密和解密方面的要求，这里就不涉及了，只需在在打包之后加密，解包之前解密即可。

## 2.4 连接进程
---
可以看出，每个客户端连接上服务器后，它所有的代码都在这个连接进程中执行，包括消息处理，handle_info，handle_cast, handle_cal，但是我并不希望在添加新的逻辑的时候还需要改动conn.erl源码，所以我加入了一个api让你可以插入自己的消息处理模块：

```
%% 指定player.erl模块处理conn.erl模块的各种消息.
conn_config:callback(player) 
%% 需要实现以下回调函数: 
join(_UID) ->
  ok.

quit(_Reason, _State) ->
  ok.

cast(C, State) ->
  State.

info(C, State) ->
  State.

call(C, From, State) ->
  State.
```
可以通过阅读conn.erl源码查看其调用点。


# 3 数据处理 slg-model
---

[slg-model](https://github.com/zhuoyikang/slg-model)是我项目里处理玩家数据的全部内容。

一个服务最重要的就是数据，这里我采用MySql做玩家数据持久化，先讨论一下问题：

1.游戏服务器一般将数据持久化到数据库，在玩家登录时将其数据加载到内存，并在内存中进行各种逻辑操作，然后定时的将其数据写回到数据库持久化。

2.游戏服务器有这样一个性质，比如你有400W用户，可能只有几十W是活跃的，这个时候如果把全部的玩家数据放到内存中就是对内存极大的浪费，所以需要有一个机制来清除掉不活跃的玩家数据。


所以这个时候我们需要用erlang实现一个对玩家数据的内存缓存机制，我使用ets表处理。

## 3.1 ets vs 进程字典
---

进程字典和ets都是erlang的数据存储机制，最初的时候我使用了进程字典存储玩家数据，即在玩家登陆时将其数据加载到进程字典，玩家登出之后将进程字典里的数据会写到mysql，这样会有以下问题：

* 基本无法编写单元测试：进程字典是一种副作用非常大的存储机制，它破坏了函数式编程的编程思想，本来函数式是最好写单元测试，但是现在你不得不为了做单元测试开一个进程，并且必须假定你的代码是执行在玩家进程里。
* 必须使用防御式编程：erlang是一门不推荐你使用防御式编程的语言，因为erlang的进程的崩溃不会造成整个系统的崩溃，这时候如果操作逻辑上有错误，但是错误是由bug或者不合理的输入操作的，崩溃即可。但是如果使用进程字典管理玩家数据，如果进程崩溃进程字典数据会丢失，所以你不得不使用防御式编程，造成编写大量丑陋的代码。
* 如果你还是要用进程字典，应该用它存放一些临时数据，那种丢失了也无所谓的数据。

选择ets是因为ets是erlang原生提供的内存表，这里用来做玩家数据表非常合适。

*为什么不使用 mnedia?*

mnesia是erlang提供的分布式数据库，功能比较强大，但它的功能对于我设计游戏服务器并不是有用，暂时没有需要使用mnesia的理由，如果设计单服的游戏服务器，并且要防止单点故障，那么可能用mnesia比较合适。

*为什么要按模块表组织玩家数据?*

有很多游戏都只在mysql里面存储一个完整的二进制程序镜像，即只有一张表，两个字段(玩家id，玩家数据)，这样编程是非常简单方便，但是有以下问题：

* 手机游戏中，游戏时间是零碎的，所以很多游戏操作都是异步的，也就是你不能像很多RPG端游或页游一样假定你看到的这个玩家一定在线。
* 你有一个好友列表，要查看他们的用户名和等级，但是你的数据没有分表存储，所以你必须把整个玩家数据load到内存中，这十分不经济。

分表存储的意思是不同的模块有单独的数据表，比如建筑表，玩家基本信息表，好友表，这样有以下好处。

* 灵活的加载你需要的任何一部分数据，只看基本信息就加载基本表，看其建筑信息就加载建筑表中他的数据，非常灵活。
* 如果一个玩家登陆，只升级的一个建筑而已，那我只需要更新他的建筑表的一条数据而已，而不是全部。
* 方便进行内存清理，因为不同模块的数据活跃性质有可能不一样，这时候可以分别处理。

所以我选择ets在内存中建立Mysql数据表的cache。

## 3.2 ets cache
---
cache是计算机里一个很普遍的概念，这里的理论思想是：内存中读取或者修改一点数据大概比硬盘上的读取修改快10000倍，保持大量的操作在内存中进行将极大的提高服务器的相应速度，有以下几个操作：

* 读取：先在对应的ets cache表中查询，如果没有再从Mysql中加载。
* 更新：先在ets表中更新，产生一个更新事件给持久化进程同步。
* 新建：现在ets表中新建，产生一个新建事件给持久化进程同步。
* 删除：现在ets表中删除，产生一个删除事件给持久化进程同步。

所以，增删查改都尽可能的在内存中进行了。下面先对MySQl层进行描述。

## 3.3 MySQl持久化
---
对玩家数据的处理不外乎增删查看，分别对应着Mysql中的insert, delete, select, update四种操作。
这时候有两部分工作，分别是SQL拼接和SQL执行。

### 3.3.1 SQL 拼接
---

SQL是字符串，我们的目的针对不同的操作编写erlang的接口模块，这样直接在erlang模块函数上操作，而不是每个人都自己用io_lib:format拼接。

这个模块的代码在[model_sql.erl](https://github.com/zhuoyikang/slg-model/blob/master/src/model_sql.erl)，我将分别对其进行详细描述：

```
%% 拼接表格的fileds列表, select @(name, type, level)，只接受原子参数.
k_column(S) when is_atom(S) -> "`"++ atom_to_list(S) ++ "`".

k_column_list(all) -> ["*"];
k_column_list([H]) ->
  H1 = k_column(H), [H1];
k_column_list([H|L]) ->
  H1 = k_column(H),
  [H1, ", "] ++ k_column_list(L).
k_column_list_test() ->
  ["*"] = k_column_list(all),
  ["`name`"] = k_column_list([name]),
  L = ["`name`", ", ", "`password`"] = k_column_list([name, password]),
  <<"`name`, `password`">> = list_to_binary(L),
  ok.  
```

如注释所言，k_column_list函数是为了满足select语句中的查询列表，当然还有update语句中的更新列表。

```
%% 拼接语句中可能出现的value列表，只接受数字，二进制和列表
v_column(V) when is_integer(V) -> integer_to_list(V);
v_column(<<V/binary>>) -> <<$", V/binary, $">>;
v_column(V) when is_list(V) ->
  B = list_to_binary(V),
  <<$", B/binary, $">>.

v_column_list([H]) ->
  H1 = v_column(H), [H1];
v_column_list([H|L]) ->
  H1 = v_column(H),
  [H1, ", "] ++ v_column_list(L).
v_column_list_test() ->
  [<<"\"name\"">>] = v_column_list([<<"name">>]),
  L = [<<"\"name\"">>, ", ", <<"\"password\"">>] = v_column_list([<<"name">>, <<"password">>]),
  <<"\"name\", \"password\"">> = list_to_binary(L),
  ok.
```

v_column_list是为了实现更新语句中的更新数据列表。

```
%% 条件语句
condition({Key, in, ValueList}) ->
  [" WHERE "] ++ k_column(Key) ++ " IN (" ++ v_column_list(ValueList) ++ ")";
condition(all) ->
  [];
condition(Cond) ->
  [" WHERE "] ++ kv_column_value_list(" and ", Cond).
```

这里是一个select语句的使用例子：

```
%% 拼接查询语句
select(Table, Column, Cond) ->
  L = "SELECT " ++ k_column_list(Column)  ++ from(Table) ++ condition(Cond) ++";",
  list_to_binary(L).
select_test() ->
  <<"SELECT `id`, `name` FROM `users` WHERE `id` = 23;">>
    = select(users, [id, name], [{id, 23}]).
```

一个update操作的例子：

```
%% 拼接更新语句
update_test() ->
  <<"UPDATE `user` SET `name` = \"fe\", `value` = \"fewf\" WHERE `id` = 23;">>
    = update(user, [{name, <<"fe">>}, {value,  <<"fewf">>}], [{id, 23}]).
```

一个delete的例子：

```
delete_test() ->
  <<"DELETE FROM `user` WHERE `id` = 23;">>
    = delete(user, [{id, 23}]),
  <<"DELETE FROM `user` WHERE `id` IN (1, 2, 3);">>
    = delete(user, {id, in, [1,2,3]}).
```

所以，你可以看到它们只是字符串拼接处理而已，这里就不一一描述了。

### 3.3.2 SQL 执行
---
使用现成的[erlang-mysql-driver](https://github.com/dizzyd/erlang-mysql-driver.git)进行，我把执行操作封装到了[model_exec.erl](https://github.com/zhuoyikang/slg-model/blob/master/src/model_exec.erl)。

每一个函数都有以下两种API，分别以_t和_n结尾：

```
%% 不指定poll，用于事务.
select_t(SQL) ->
select_t(RecordName, SQL) ->

%% 执行select语句。
select_n(Poll, SQL) ->
select_n(Poll, RecordName, SQL) when is_atom(Poll) ->
…
```

* _n结尾的函数可以在第一参数指定连接池.
* _t结尾的函数用于事务操作，这是erlang-mysql-driver的接口规范:

如果你没有使用过erlang-mysql-driver，需要详细阅读一下一个例子：[erlang-mysql-driver-test](https://github.com/dizzyd/erlang-mysql-driver/blob/master/test/mysql_test.erl)

这里是slg-server的依赖配置：[rebar.config](https://github.com/zhuoyikang/slg-model/blob/master/config/rebar.config)

### 3.3.3 组合操作
---

既然有SQl拼接和SQL执行，就可以编写出完整的增删查改接口函数:[model.erl](https://github.com/zhuoyikang/slg-model/blob/master/src/model.erl)

```
%% 开启一个poll
start(DbsConf) ->
  #db_conf{poll=Poll, host=HostName, port=Port, username=UserName,
           password=Password, database=DataBase, worker=Worker} = DbsConf,
  mysql:start_link(Poll, HostName, Port, UserName, Password, DataBase, fun logger/4),
  [mysql:connect(Poll, HostName, undefined, UserName, Password, DataBase, true) ||
    _ <- lists:seq(1, Worker)],
  Poll.
```
这里是使用erlang-mysql-driver开启一个连接池，使用方法可以看erlang-mysql-driver的文档或者源码。

你可以看到，仅仅是组合而已：

```
select_t(Record, Table, Column, Cond) ->
  SQL = model_sql:select(Table, Column, Cond),
  model_exec:select_t(Record, SQL).

select_n(Poll, Record, Table, Column, Cond) ->
  SQL = model_sql:select(Table, Column, Cond),
  model_exec:select_n(Poll, Record, SQL).
  
… 省略  
```

## 3.4 动态model模块
---
slg-model会为每一个MySql表产生一个动态的erlang模块，使用了[smerl](https://github.com/yariv/erlyweb/blob/master/src/smerl/smerl.erl)处理，它来源于[erlyweb](https://github.com/yariv/erlyweb?source=c)项目，为erlang提供了基础的动态编程能力，非常好用。

使用例子：

```
%%  test_smerl() ->
%%    M1 = smerl:new(foo),
%%    {ok, M2} = smerl:add_func(M1, "bar() -> 1 + 1."),
%%    smerl:compile(M2),
%%    foo:bar(),   % returns 2``
%%    smerl:has_func(M2, bar, 0). % returns true
```

我把这个模块收录到了[slg-support](https://github.com/zhuoyikang/slg-support)项目。

为了方便理解，这里有一个实体的表model模块例子:[model_buildings.erl](https://github.com/zhuoyikang/slg-model/blob/master/src/model_building.erl)

可以看出函数分成事务和非事务两组：

```
select(Poll, Cond) when is_list(Cond) ->
  model:select_n(Poll, db_building, buildings, all, Cond);
select(Poll, UserId) ->
  model:select_n(Poll, db_building, buildings, all, [{user_id, UserId}]).

%% 通过外键查询
select(Cond) when is_list(Cond) ->
  model:select_t(db_building, buildings, all, Cond);
select(UserId) ->
  model:select_t(db_building, buildings, all, [{user_id, UserId}]).

```

update操作有两个，其中第2个update(Poll, DbBuilding)直接使用与数据表对应的record实体做参数。

```
update(Poll, {Id, List}) ->
  List1 = model:pos_attr(model_record:m(buildings), List),
  model:update_n(Poll, Id, buildings, List1);
update(Poll, DbBuilding) ->
  model:update_n(Poll, model_record:m(buildings), buildings, DbBuilding).
```

## 3.5 Ets Record MySql映射
---
上文已经描述过，每个ets表将对应一个MySql表，而MySql表的字段结构将由一个record来描述，这个record将存储到ets里。

比如有以下MySql表，users:

```
+------------+-------------+------+-----+---------+-------+
| Field      | Type        | Null | Key | Default | Extra |
+------------+-------------+------+-----+---------+-------+
| id         | bigint(20)  | NO   | PRI | NULL    |       |
| user_id    | bigint(20)  | NO   |     | NULL    |       |
| device_id  | int(11)     | NO   |     | NULL    |       |
| name       | varchar(30) | NO   | UNI | NULL    |       |
| level      | int(11)     | NO   |     | NULL    |       |
| experience | int(11)     | NO   |     | 0       |       |
| sex        | tinyint(4)  | NO   |     | -1      |       |
+------------+-------------+------+-----+---------+-------+
```

将有一个与其对应的record:

```
%% # 玩家基本信息
-record(db_user, {
          id = <<"0">> :: binary(),
          user_id = <<"0">> :: binary(),
          device_id = <<"0">> :: binary(),
          name = <<"">> :: binary(),
          level = 0 :: integer(),
          experience = 0 :: integer(),
          sex = 0 :: integer()
         }).
```

slg-model约定一个表采用复数，比如users，而其对应的record使用db_前缀加上其单数表示:db_user，动态模块使用model_加上表名字(model_users)。

你可以看到这个db_user record和MySql表的每个字段一一对应，另外还有两点注意：

* id:id是表的主键，这里采用bigint，因为考虑到合服的情况，程序保留每个主键数字的后3位为服务器标识，这样就算有多个服务器也不会有id冲突，合服的时候只需要做表合并即可。
* varchar:字符串类型在程序中一律使用binary类型描述，因为erlang对字符串支持不好，而且如果设计到多语言问题，list更是没有办法表达，所以只有用binary。

所以动态模块的update函数中有一个直接使用DbRecord为参数，它将这个record里头所有的数据更新到MySQL。

## 3.6 data_holder
---
每个ets表都要有一个拥有者，这也是[data_holder](https://github.com/zhuoyikang/slg-model/blob/master/src/data_holder.erl)进程存在的主要作用。

它的代码很简单，主要有以下两个部分需要注意：

*init 函数*

```
init([Dbc, Key]) ->
  data_ets:new(Key),
  model:module_new(Key),
  model:start(Dbc#db_conf{poll=model:atom_poll(Key, read), worker=3}),
  model:start(Dbc#db_conf{poll=model:atom_poll(Key, write), worker=1}),
  MaxId = max_id(model:atom_poll(Key, read), Key),
  data_guard_super:start_guard(Key),
  data_writer_super:start_writer(Key),
  data_clear_super:start_clear(Key),
  {ok, {Key, MaxId, Dbc}}.
```

data_holderl进程启动时将：

* 1.建立ets表。
* 2.建立动态模块。
* 3.开起两个连接池，分别用于对MySQl的读写。
* 4.开启一个guard进程。
* 5.开启一个MySql回写进程。
* 6.开启一个数据清理进程。

这个进程里面引入了3个还没有描述的东西：guard，writer和clear，之后会对它们进行详细描述。

*ID函数* 

```
id(Key) ->
  Atom = model:atom(holder, Key),
  gen_server:call(Atom, id).
```

每个data_holder进程将提供id生成功能，它将用于为每个表产生唯一id。


















