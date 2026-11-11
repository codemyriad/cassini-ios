// Python 3 zipfile.ZIP_DEFLATED, Random(42) byte block of2048 repeated100 times. Synthetic bytes only.
// Independent implementation fixture; SHA-256 describes the uncompressed bytes.
import Foundation
enum ZIPDeflateFixture {
    static let digest = "d239e1ce3669fa0febd6ec87461767c9e8451fffae354c71e4b26e5ed7250551"
    static let data = Data(base64Encoded: """
UEsDBBQAAAAIAIZVa12QpoNPQA0AAAAgAwASAAAAZm9sZGVyL0VuZ2xpc2gud2F27dWHXw4IA8BxHfdmlU4pRaKUulxRKZKkUlIa5MguV2dEJbQHjica16Kl
FNGgLuSIEhVeDQ1JiIbKo61kZL3/x/v5ff+J76KJYQH7zHXmNkpM0nTzEnNucO+IGG3XmBths/eSjmbJ/Ot5AunupXdVTxU4Kcnsj1X10i6JEN5cU3Rtd8js
dQFrekpOuF+YfkAirer4LNc01x/lXRYC88BjLyoL3M2+akxdaG3XOPNeaX/wz/ohuYtOvbIVihzbqBvvbF28etT5kXGLCpJ95f1U1T8pGS0bshc0urqcqSxu
ebMk0HNmzvgD7qNnzzigKJE12yfi0x6TQf/BGsd585uuNdb1T9NSeJSjF+Tk2GHeuDmiJ0ilTUtWVNNnbc2nD3uqZtiXiDwQCKMbP9s4xrnJK6TKy763lVfb
qqTo/WhJoJRaQ9rRHam+gnKThK405TFd2sp7BCZXlAKKomxbEsckLDAVLNa1CY3c/c8OwUiwnGZjuLRItvGx1W3PxyxSsZpcZNm0bEryTanru4N0rtXY+KzZ
8Hjixuy6oBA7vVLJAQ+X7qun9++b6FSZGaEUcbUyS3zx0Y0CSb1XeanNi+85HpZuHvXHzSalrNSlCSm1GY/iljk9LXFIrB6VFL27Kb2vrW3P4O/qURc1vVM8
nS0nygQMKb+t3172rdLf8ifdZ+4bemWDDN+a9p5te95uN9T5V2D4J9+w1jnR3qEXz6mZrTpYZr1nZn1NVl+9ws6nD8aXvB+dH/+gwf2ze2jzJ/EHl6rt+5eJ
PRT79cXyns2yR0syXIUZl0oinh5SGxgnd3WfktSkQJfx1r5Gg/pufUcK1+qvOaMnduZOhbOKv07ikimXXxQp5f7n6Yjuy4Ju61cbTnzsaz5+PmBuRKd/b8kl
8W8XNn92vfZX7t/hPzuq+9WM+A196Rirecqj2v904WDes6x84YnTwQeXOKUt2eK092N4pPb2uP03NiaKGoXJTDtp9EXnP1EDw625W+QOvdefVfVFedoqqyT1
IIMnniWdbfEvTs/Q2uUqULP1Xa9iK1LbOXBS4mBMpHC2l8D5mb6nVciK2TPsk2NalvYnPQr92qIm9fJ8sJjGgfHHpRwG2iI2NX/RGLhSm52+YHVm3beYqsnC
39IOnV/8aFTP42nbCn60ye0IMYlp+WQo7mt3RrRG01O/x8D6x8nQ+o/v/N+uLHNcrhRenxsiEhk/YtX+MS/77tv0bb5lXnXSZwdL7636NtkoS7tV+62oRa2N
yoAgp0Its+Ts58lK3jH7NV5pab9emyAuc2H6qevFTSsD6jatc1At9ftucbDncPfhMX0xtspteQnPgt8mOpd91PUpvR4XN6E8bIzs9+gD+e6OwWbzpVJaf7lp
ohGXUe/gYnIr1P7Ih7gc/X6VFZ4VtzTKRQVLhYXHSm/reb2bmOExszexdrG5jGTS18XzvZffFxY12NRrjdT8LVHk9vq1d4FW4XWFinBHQ6GG63jZbH+jnUq7
9nplWoqErzQOdlgoZiJ63ef8WAeBnNFT/ZlDHQV6bzykE7smKQxXPdf78lpZLd1yllHYhdJTwiYt/b1Nb/Y/zhFW1s9LfZ56uNh6UFFDXfPl/NvGMzIN6641
ysWcyV/gavNhn97VQv0IzxdiIeKbQlNyro7eZFGltGKSxt47DcJc26IzF9TlbGxl1ULbnn1qqw/dq5/XtDDqc7KMe/n00TsSXc0Ox2YsGf29ycG45MC12RVT
msd1z0l9Uf0kVr96/IV13QW/Nev6N1eplqfkeGT/Pkd/+5Wrlt46K484r7dW2fC1t+N82qpWxYG2pLDp+copPW8k5Quj52iU9Uzp3JY+tEqhU+cf9fVSgS0t
djdvR96vzZG7OCtz3r2oQ1bZaiuupvzXWD3lTuYyzcaCcQUpm/bkfnLyNLOZE6ctecnkjvWaTfYt0nU3fV5HdXj5pgxsL2ztiSxtWO1iFiz34bbO0qhfV4d2
WjZreHReEaufVl7sfU+teJ/4Oa2LK80ko9+ZD3T8pDruyF6rxoUxPomGU30bumYu/DHWz+Lki1H5fk+2qt9QHP9gQPp+8aGx/yrm+S3INpXOz3HoHd68fGbX
5FN/SrtMSUupGDw02TH636lZoUsLmytb7+Vs/f69MOTXZ6pNm06l66hmxJ1uf7729dX2KfmvwuRVqm/aTbJo+cVI0ftWQZmEdWfR7ddzzG5VpEYE6Ytt/XHf
4NjR9j3RX1wMlyu/Wf967rnLs2ITbB0K9hm6mPt8FbtR2G88d1ZKxXBdrbLRWeXOvrxlm41fTl9qnWS/+rzn5SjV4D/CjJI0f7ded2mKuJqMYPeTSd9jEz8G
VMcLlWfYttZ/7N2Ra5F6Lq/SuEj3nF+fYUhn4Ir5srFlDUF2GamOdj/6fyR/n6DxsMtvb/5U2chvA9Fj9JpMBbce3ZKpktteEKN8r/Nvg2XzHxbn3LJwrpKS
kTTLHnxrZZ5xbs3DhEsjCUNjC7MWPkkWGxTslxteV2LpL7HQcVxrasOqxzvq3imY7brw/k7q+u5/rgk+OgVGxHvGx+waOTt8JSzGsKQ8b2XslBjVy21Hhvf8
eSLUTM/XX9bTS077cdY7bbOfbGuG3rvEpEfP+O2gpMOTDZMrvm2NlRwTr3sxSvjVtD/UaVHWmq4jW0UvxTk5VD/PmFs1b4v5+/NBo4+WebeHZCb+fPSGt4JB
X7Jd9RmDuEIPd9P31sLi+ndugWrtBXMWKfxpZZ/RtnjniEb7dKFJ/Vv5nuQJ5YdF3JRlGvNmzlB6JxFdu2n50+LSjrt31EyvGGx8uGyfyIT43mclBwK7L9uE
b1sk0TDWb6ei9i/tUwOkq1q83Kabx3qdS/dJtPB4nBCm4PD829S80nNPaq0S7mwZ9PNMsOiVf/zE9L7/4R1Zqp1Fmo5yx+9KKW9zG96VnSTq6mgw7L+jwjc9
sqTvevLRRfzP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP//zP
//zP//zP//zP//zP//z/f/3//wBQSwECFAMUAAAACACGVWtdkKaDT0ANAAAAIAMAEgAAAAAAAAAAAAAAgAEAAAAAZm9sZGVyL0VuZ2xpc2gud2F2UEsFBgAA
AAABAAEAQAAAAHANAAAAAA==
""", options: .ignoreUnknownCharacters)!
}
